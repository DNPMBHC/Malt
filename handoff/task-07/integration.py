#!/usr/bin/env python3
"""Run local integration tools without treating simulations as guest evidence."""

import argparse
import ast
import json
import pathlib
import shutil
import sys
import tempfile

from phase2_evidence import validate_phase2_evidence
from verify import Redactor, digest, discover, process_environment, run_stage


def resolve_windows_probe_dir(root):
    """Prefer the canonical subrepo Modules/module-a/WindowsProbe path with fallback to legacy top-level path."""
    repo, _, _, _ = discover(root)
    canonical = repo / 'Modules/module-a/WindowsProbe'
    if (canonical / 'CMakeLists.txt').is_file():
        return canonical
    return root / 'Modules/module-a/WindowsProbe'


def resolve_host_tool(name):
    """Locate host tools on PATH or standard Homebrew/local install prefixes without mutating global config."""
    found = shutil.which(name)
    if found:
        return found
    for prefix in ('/opt/homebrew/bin', '/usr/local/bin'):
        candidate = pathlib.Path(prefix) / name
        if candidate.is_file():
            return str(candidate)
    return name


def check_module_a_symlink_consistency(root):
    repo, _, _, _ = discover(root)
    canonical = repo / 'Modules/module-a'
    legacy = root / 'Modules/module-a'
    if not canonical.exists():
        return False
    if not legacy.exists():
        return True
    return canonical.resolve() == legacy.resolve()


def local_python_inputs(seeds):
    """Follow local imports without adding caches or installed library inputs."""
    pending = list(seeds)
    inputs = set()
    while pending:
        path = pending.pop()
        if path in inputs:
            continue
        inputs.add(path)
        try:
            tree = ast.parse(path.read_text())
        except (OSError, SyntaxError):
            continue
        for node in ast.walk(tree):
            names = ([item.name for item in node.names] if isinstance(node, ast.Import)
                     else [node.module] if isinstance(node, ast.ImportFrom) and node.module else [])
            for name in names:
                candidate = path.parent / (name.split('.')[0] + '.py')
                if candidate.is_file():
                    pending.append(candidate)
    return inputs


def integration_inputs(root):
    """Inventory only inputs consumed by this integration command batch."""
    task = pathlib.Path(__file__).resolve().parent
    graphics = root / 'graphics-lab'
    vendor = root / 'handoff/module-f'
    abi = resolve_windows_probe_dir(root)
    inputs = local_python_inputs([task / 'integration.py', *task.glob('test*.py')])
    # The probe wrapper is started by a graphics test, rather than imported.
    inputs |= local_python_inputs([*graphics.glob('test*.py'), graphics / 'run_probe.py'])
    inputs.add(graphics / 'metal_host.swift')
    # The SDK compile test reads Swift inputs, which Python import traversal cannot follow.
    _, _, package, _ = discover(root)
    sdk_compile_sources = (
        'HostMetalFXBenchmark.swift',
        'HostMetalFXBenchmarkGPUContext.swift',
        'HostMetalFXBenchmarkGPUPath.swift',
    )
    inputs |= {path for name in sdk_compile_sources
               for path in package.glob('Sources/*/Runtime/' + name)}
    # The validator reads the JSON and scans these same top-level deliverables.
    inputs |= {path for path in vendor.iterdir()
               if path.is_file() and path.suffix in {'.md', '.json', '.py'}}
    inputs |= {abi / 'CMakeLists.txt', abi / 'tests/protocol_abi_test.c',
               abi / 'shared/module_a_protocol.h'}
    return inputs


def input_snapshot(root, redactor, output):
    """Keep all anonymized input entries, including any name collisions."""
    output = output.resolve()
    grouped = {}
    for path in sorted(integration_inputs(root)):
        if path.resolve().is_relative_to(output):
            continue
        name = str(path.relative_to(root))
        try:
            value = digest(path.read_bytes())
        except OSError:
            value = None
        grouped.setdefault(redactor(name), []).append((name, value))
    return {key if len(entries) == 1 else key + '#input-' + digest(name.encode())[:16]: value
            for key, entries in grouped.items() for name, value in entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent / 'evidence/integration')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    repo, _, package, _ = discover(root)
    output = args.output.resolve()
    if any(path.resolve().is_relative_to(output) for path in integration_inputs(root)):
        parser.error('output directory overlaps integration inputs')
    output.mkdir(parents=True, exist_ok=True)
    stages = {}
    graphics_source = root / 'graphics-lab/metal_host.swift'
    graphics_before = digest(graphics_source.read_bytes())
    with tempfile.TemporaryDirectory(prefix='task-07-integration-') as temporary:
        cache = pathlib.Path(temporary)
        redactor = Redactor(root, repo, package, cache)
        env = process_environment()
        inputs_before = input_snapshot(root, redactor, output)
        cmake_bin = resolve_host_tool('cmake')
        ctest_bin = resolve_host_tool('ctest')
        probe_dir = resolve_windows_probe_dir(root)
        commands = [
            ('performance-tools', [sys.executable, '-B', '-m', 'unittest', 'discover', '-v'], pathlib.Path(__file__).resolve().parent),
            ('graphics-tools', [sys.executable, '-B', '-m', 'unittest', 'discover', '-v'], root / 'graphics-lab'),
            ('graphics-typecheck', ['xcrun', 'swiftc', '-typecheck', str(graphics_source)], root),
            ('graphics-build', ['xcrun', 'swiftc', '-O', str(graphics_source), '-framework', 'AppKit',
                                '-framework', 'Metal', '-framework', 'QuartzCore',
                                '-o', str(cache / 'graphics-host')], root),
            ('vendor-evidence', [sys.executable, '-B', 'validate_evidence.py', '--self-test'], root / 'handoff/module-f'),
            ('driver-abi-configure', [cmake_bin, '-S', str(probe_dir), '-B', str(cache / 'driver-abi')], root),
            ('driver-abi-build', [cmake_bin, '--build', str(cache / 'driver-abi')], root),
            ('driver-abi-test', [ctest_bin, '--test-dir', str(cache / 'driver-abi'), '--output-on-failure'], root),
        ]
        for name, command, cwd in commands:
            stages[name] = run_stage(name, command, cwd, env, output, redactor, 90)
        binary = cache / 'graphics-host'
        graphics_binary = digest(binary.read_bytes()) if binary.is_file() else None
        inputs_after = input_snapshot(root, redactor, output)
    graphics_after = digest(graphics_source.read_bytes())
    inputs_stable = bool(inputs_before) and inputs_before == inputs_after and all(
        value is not None for value in inputs_before.values())
    phase2_report = validate_phase2_evidence(root / 'handoff/phase-2/evidence')
    report = {
        'schema': 'task-07-integration-v2',
        'stages': stages,
        'phase2Evidence': phase2_report,
        'moduleACanonicalSymlinkConsistent': check_module_a_symlink_consistency(root),
        'passed': all(stage['exitCode'] == 0 for stage in stages.values())
                  and phase2_report['passed']
                  and check_module_a_symlink_consistency(root)
                  and graphics_before == graphics_after and inputs_stable,
        'inputSHA256': inputs_before,
        'inputFingerprintSHA256': digest(json.dumps(inputs_before, sort_keys=True).encode()),
        'inputCount': len(inputs_before),
        'inputsStableDuringRun': inputs_stable,
        'changedInputs': sorted(key for key in inputs_before.keys() | inputs_after.keys()
                                if key not in inputs_before or key not in inputs_after
                                or inputs_before[key] != inputs_after[key]),
        'graphicsSourceSHA256': graphics_after,
        'graphicsSourceStableDuringRun': graphics_before == graphics_after,
        'graphicsBinarySHA256': graphics_binary,
        'scope': 'local test tools, portable C ABI, and evidence semantics only',
        'runtimeEnvironment': {
            'status': 'environment_not_verified',
            'utmCLIOnPATH': shutil.which('utmctl') is not None,
            'utmApplicationInstallation': 'not_probed',
            'guestConfiguration': 'not_probed',
            'realGuestExecuted': False,
            'affectsLocalGatePass': False,
            'reason': 'Missing UTM or guest is an environment prerequisite, not a feature failure. '
                      'This local-only gate does not inventory VMs or execute a real guest; '
                      'CLI absence on PATH does not prove the application is absent.',
        },
        'realDriverLoaded': 'not_verified',
        'gameProtection': 'not_verified',
        'onlineGameSession': 'not_tested',
        'gamePerformance': 'not_tested',
    }
    (output / 'integration.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

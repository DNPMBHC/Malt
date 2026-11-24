#!/usr/bin/env python3
"""Mount the release image and render through moved and missing-driver copies. @DNPMBHC."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

import artifact_perf_gate as gate
from runtime_bundle_gate import probe_driver, verify_hardened


def smoke_copy(app, workspace, temporary, engines, missing_driver=False):
    app_bin, cli, identity = gate._find_packaged_cli(app)
    gate._redact_product = re.escape(app_bin.name)
    gate._redact_driver = r'kosmickrisp'
    gate._redact_identity = re.escape(identity)
    manifest = json.loads((app / 'Contents/Resources/runtime-manifest.json').read_text())
    component = next(c for c in manifest['components'] if c.get('requiredVulkanFeatures'))
    driver_name = next(a['name'] for a in component['artifacts'] if a['name'].startswith('libvulkan_'))
    icd_name = next(a['name'] for a in component['artifacts'] if a['name'].endswith('_icd.json'))
    driver = app / 'Contents/Frameworks' / driver_name
    loader = app / 'Contents/Frameworks/libvulkan.1.dylib'
    icd = app / 'Contents/Resources/vulkan/icd.d' / icd_name
    if missing_driver:
        driver.unlink()
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', str(app)],
                       capture_output=True, check=True)
    signature = verify_hardened(app)
    icd_data = json.loads(icd.read_text())
    relative = icd_data['ICD']['library_path']
    relative_ok = not pathlib.Path(relative).is_absolute() and (icd.parent / relative).resolve() == driver.resolve()
    features = None if missing_driver else probe_driver(loader, icd)
    home = temporary / 'home'
    home.mkdir()
    launcher = temporary / 'wine-reference-launch'
    subprocess.run(['xcrun', 'swiftc', str(pathlib.Path(__file__).with_name('wine_reference_launch.swift')),
                    '-o', str(launcher)], capture_output=True, check=True, timeout=60)
    gate._mount_sandbox_runtime(temporary / 'runtime', engines, app_bin.name)
    env = os.environ.copy()
    for key in ('VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'VK_ADD_DRIVER_FILES', 'WINE_SONAME_LIBVULKAN',
                'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE', 'DXMT_CONFIG',
                'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'WINEDLLPATH'):
        env.pop(key, None)
    env.update(CFFIXED_USER_HOME=str(home), WINEDEBUG='-all')
    env[app_bin.name.upper() + '_RUNTIME_ROOT'] = str(temporary / 'runtime')
    bottle = gate._create_and_configure_bottle(cli, env, 'relocation-smoke', 'dxvk')
    try:
        gate._init_bottle_prefix(bottle, engines, 'dxvk', temporary / 'cache')
        shell = subprocess.run([str(cli), 'shellenv', 'relocation-smoke'], env=env,
                               capture_output=True, text=True, check=True, timeout=60)
        values = gate.parse_shell_environment(shell.stdout)
        selected = gate.runtime_path_matches(values.get('VK_DRIVER_FILES'), icd) and (
            gate.runtime_path_matches(values.get('WINE_SONAME_LIBVULKAN'), loader))
        fallback = values.get('WINE_SONAME_LIBVULKAN', '').endswith('libMoltenVK.dylib') and not values.get('VK_DRIVER_FILES')
        probe = temporary / pathlib.Path(gate.PROBE_RELPATH).name
        shutil.copy2(workspace / gate.PROBE_RELPATH, probe)
        csv = temporary / 'relocation.csv'
        values.update(XDG_CACHE_HOME=str(temporary / 'cache'), VK_LOADER_DEBUG='driver')
        values.pop('PATH', None)
        gate.configure_probe_environment(bottle, probe, values, launcher)
        expected = {'driver': engines['mvk_root'] / 'external/libMoltenVK.dylib'} if missing_driver else {
            'loader': loader, 'driver': driver}
        args = [str(cli), 'run', '--bottle-path', '--', str(bottle), str(probe),
                '--frames', '120', '--warmup', '9000', '--width', '1280', '--height', '720',
                '--commands', '16', '--resource-bytes', '65536', '--completion-mode', 'gpu-complete',
                '--csv', 'Z:' + str(csv).replace('/', '\\')]
        started = time.time()
        code, stdout, stderr, mapped = gate.run_mapped_probe(args, env, expected, cwd=temporary)
        metrics = gate.summarize_probe_csv(csv) if code == 0 and csv.exists() else {'frameCount': 0}
        log = gate._redact_run(stdout + '\n' + stderr + '\n' + gate.read_probe_logs(home, started), workspace, temporary)
        result = {'owner': '@DNPMBHC', 'driverRemoved': missing_driver, 'hardenedRuntime': signature,
                  'relativeICDVerified': relative_ok, 'vulkanFeatures': features,
                  'optionalDriverSelected': selected, 'compatibilityFallbackSelected': fallback,
                  'fallbackReason': 'missing_locked_driver' if missing_driver and fallback else None,
                  'actualMappedLibraries': mapped, 'renderExitCode': code, 'renderMetrics': metrics,
                  'csvSHA256': gate.sha256_file(csv) if csv.exists() else None,
                  'passed': signature['passed'] and relative_ok and code == 0 and metrics['frameCount'] == 120
                            and len(mapped) == len(expected) and (fallback if missing_driver else selected)}
        return result, log, csv
    finally:
        gate.stop_bottle_prefix(engines, bottle, env)
        gate.remove_isolated_directory(bottle)
        gate.remove_isolated_directory(temporary / 'cache')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dmg', type=pathlib.Path, required=True)
    parser.add_argument('--release-manifest', type=pathlib.Path, required=True)
    parser.add_argument('--scratch-root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    workspace = pathlib.Path(__file__).resolve().parents[2]
    engines = gate._discover_engine_layout(gate.DEFAULT_ENGINE_ROOT)
    release = json.loads(args.release_manifest.read_text())
    dmg_matches = gate.sha256_file(args.dmg) == release['artifacts']['dmg']['sha256']
    args.scratch_root.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    results = {}
    with gate.isolated_temporary_directory(prefix='demo-app-relocation-', dir=args.scratch_root) as tmp:
        temporary = pathlib.Path(tmp).resolve()
        mount = temporary / 'mounted-image'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(args.dmg)],
                       capture_output=True, check=True, timeout=60)
        try:
            original = next(mount.glob('*.app'))
            for label in ('moved', 'missing-driver'):
                target = temporary / label
                target.mkdir()
                app = target / 'demo-app.app'
                shutil.copytree(original, app, symlinks=True)
                result, log, csv = smoke_copy(app, workspace, target, engines, label == 'missing-driver')
                results[label] = result
                (args.output.parent / (label + '-smoke.log')).write_text(log)
                if csv.exists():
                    shutil.copy2(csv, args.output.parent / (label + '-smoke.csv'))
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], capture_output=True, check=True, timeout=60)
        report = {'owner': '@DNPMBHC', 'mountedActualDMG': True, 'releaseImageSHA256Matched': dmg_matches,
                  'imageSHA256': gate.sha256_file(args.dmg), 'scenarios': results,
                  'passed': dmg_matches and all(r['passed'] for r in results.values()),
                  'scope': 'Synthetic D3D11 render through copies from the actual release image; no commercial game claim.'}
        args.output.write_text(gate._redact_run(json.dumps(report, indent=2), workspace, temporary) + '\n')
    print(json.dumps({'passed': report['passed'], 'scenarios': {k: v['passed'] for k, v in results.items()}}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

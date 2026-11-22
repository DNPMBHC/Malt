#!/usr/bin/env python3
"""Exercise the built CLI parser without reading user bottle data or launching games."""

import json
import os
import pathlib
import signal
import subprocess
import tempfile

from verify import Redactor, digest, discover, process_environment, run_stage
from run_cli_checks import run_cli_checks
from storage_cli_checks import storage_checks


def evaluate_check(result, text, expected, required, forbidden=()):
    diagnostics_present = all(value in text for value in required)
    forbidden_absent = not any(value in text for value in forbidden)
    return {'exitCode': result['exitCode'], 'expectedExitCode': expected,
            'requiredDiagnosticsPresent': diagnostics_present,
            'forbiddenDiagnosticsAbsent': forbidden_absent,
            'passed': result['exitCode'] == expected and diagnostics_present and forbidden_absent}


def main():
    task = pathlib.Path(__file__).resolve().parent
    root = task.parents[1]
    repo, project, package, scheme = discover(root)
    output = task / 'evidence/cli'
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='task-07-cli-') as directory:
        redactor = Redactor(root, repo, package, pathlib.Path(directory))
        env = process_environment()
        def settings_for(selection):
            process = subprocess.Popen(
                ['xcodebuild', '-project', str(project), *selection, '-showBuildSettings', '-json',
                 '-configuration', 'Debug', '-scmProvider', 'system', '-skipPackageUpdates',
                 '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
                 '-destination', 'platform=macOS,arch=arm64', 'CODE_SIGNING_ALLOWED=NO'],
                cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                raw, errors = process.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise ValueError('build_settings_timeout')
            if process.returncode:
                (output / 'build-settings.log').write_text(redactor(errors.decode(errors='replace')))
                raise ValueError('build_settings_failed')
            return json.loads(raw)

        targets = settings_for(['-scheme', scheme])
        all_targets = settings_for(['-alltargets'])
        tool_names = {target['buildSettings']['EXECUTABLE_NAME']
                      for target in all_targets
                      if target['buildSettings'].get('PRODUCT_TYPE') == 'com.apple.product-type.tool'}
        candidates = set()
        for target in targets:
            settings = target['buildSettings']
            if settings.get('PRODUCT_TYPE') == 'com.apple.product-type.tool':
                path = pathlib.Path(settings['TARGET_BUILD_DIR']) / settings['EXECUTABLE_PATH']
                if path.is_file():
                    candidates.add(path.resolve())
            if settings.get('PRODUCT_TYPE') == 'com.apple.product-type.application':
                product = pathlib.Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']
                for path in product.glob('Contents/Resources/*'):
                    if path.name in tool_names and path.is_file() and os.access(path, os.X_OK):
                        with path.open('rb') as stream:
                            magic = stream.read(4)
                        if magic in {bytes.fromhex(value) for value in ('cffaedfe', 'feedfacf', 'cafebabe', 'bebafeca')}:
                            candidates.add(path.resolve())
        if len(candidates) != 1:
            raise ValueError('one_built_cli_required')
        executable = candidates.pop()
        # Current Run.args uses the default .remaining strategy, which excludes dash-prefixed options.
        # Both diagnostic invocations therefore fail parsing before Run.run can read bottle data.
        synthetic_bottle = str(pathlib.Path(directory) / 'missing-bottle')
        synthetic_program = str(pathlib.Path(directory) / 'missing-program.exe')
        commands = [('help', ['--help'], 0, ['run']),
                    ('run-help', ['run', '--help'], 0,
                     ['--ignore-saved-arguments', '--profile', '--bottle-path']),
                    ('storage-help', ['storage-preflight', '--help'], 0,
                     ['--target', '--guest-config', '--bottle-path']),
                    ('unknown-option', ['run', '--task-07-invalid-option', synthetic_bottle,
                                        synthetic_program], 64,
                     ["Unknown option '--task-07-invalid-option'"]),
                    ('empty-override-flag-rejects-value',
                     ['run', '--ignore-saved-arguments=unexpected', synthetic_bottle, synthetic_program],
                     64, ["The option '--ignore-saved-arguments' does not take any value"])]
        checks = {}
        for name, arguments, expected, required in commands:
            result = run_stage(name, [str(executable), *arguments], repo, env, output, redactor, 20)
            text = (output / (name + '.log')).read_text()
            forbidden = ('Missing expected argument', 'Missing value for') if expected == 64 else ()
            checks[name] = evaluate_check(result, text, expected, required, forbidden)
        storage = storage_checks(executable, repo, package, targets + all_targets, directory, env, output, redactor)
        run_e2e = run_cli_checks(executable, repo, package, targets + all_targets, directory, env, output, redactor)
        report = {'schema': 'task-07-cli-v2', 'checks': checks, 'storagePreflight': storage,
                  'runEndToEnd': run_e2e,
                  'binarySHA256': digest(executable.read_bytes()),
                  'passed': all(value['passed'] for value in checks.values())
                  and storage['passed'] and run_e2e['passed'],
                  'scope': 'parser checks, isolated synthetic storage-preflight, and isolated synthetic run E2E; '
                           'no real Wine, guest, installer, or game launch',
                  'savedArgumentOverrideEndToEnd': 'synthetic_cli_verified' if run_e2e['passed'] else 'failed',
                  'emptyOverrideRuntimeBranch': 'synthetic_cli_verified'
                  if run_e2e.get('checks', {}).get('ignoreSavedArgumentsEmptyOverride', {}).get('passed')
                  else 'failed'}
        (output / 'cli.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
        return 0 if report['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as error:
        code = str(error) if str(error) in {'build_settings_timeout', 'build_settings_failed',
                                          'one_built_cli_required'} else 'invalid_build_settings'
        report = {'schema': 'task-07-cli-v1', 'passed': False, 'error': code}
        destination = pathlib.Path(__file__).resolve().parent / 'evidence/cli'
        destination.mkdir(exist_ok=True)
        (destination / 'cli.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
        raise SystemExit(2)

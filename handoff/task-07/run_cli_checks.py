"""Exercise the built CLI run subcommand end-to-end with an isolated synthetic Wine shim."""

import hashlib
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import time

from verify import run_stage


SHIM_SCRIPT = '''#!{python}
import json
import os
import pathlib
import signal
import sys
import time

prefix = pathlib.Path(os.environ['WINEPREFIX'])
capture = {{
    'argv': sys.argv[1:],
    'pid': os.getpid(),
    'syntheticEnv': os.environ.get('SYNTHETIC_ENV'),
}}
(prefix / 'shim-capture.json').write_text(json.dumps(capture), encoding='utf-8')
mode = (prefix / 'shim-mode.txt').read_text(encoding='utf-8').strip()
if mode == 'exit-0':
    raise SystemExit(0)
if mode.startswith('exit-'):
    raise SystemExit(int(mode.split('-', 1)[1]))
if mode == 'sigterm':
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(2)
if mode == 'sigkill':
    os.kill(os.getpid(), signal.SIGKILL)
    time.sleep(2)
if mode == 'wait-cancel':
    (prefix / 'shim-ready.txt').write_text(str(os.getpid()), encoding='utf-8')
    time.sleep(30)
raise SystemExit(99)
'''


def localized_variants(repo, key, fallback, *format_args):
    """Collect English fallback and all xcstrings translations for a runtime key."""
    templates = {fallback}
    for catalog in repo.glob('*/Localizable.xcstrings'):
        try:
            strings = json.loads(catalog.read_text(encoding='utf-8')).get('strings', {})
        except (OSError, ValueError):
            continue
        translations = strings.get(key, {}).get('localizations', {})
        for item in translations.values():
            value = item.get('stringUnit', {}).get('value', '')
            if value:
                templates.add(value)
    if not format_args:
        return sorted(templates)
    formatted = set()
    for template in templates:
        try:
            formatted.add(template % format_args)
        except TypeError:
            formatted.add(template)
    return sorted(formatted)


def matches_any_localized(text, variants):
    return any(variant and variant in text for variant in variants)


def _program_settings_path(bottle, relative_posix_path):
    digest = hashlib.sha256(relative_posix_path.encode('utf-8')).hexdigest()
    return bottle / 'Program Settings' / f'v2-{digest}.plist'


def _write_program_settings(bottle, relative_posix_path, arguments, environment=None):
    path = _program_settings_path(bottle, relative_posix_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        'locale': '',
        'environment': environment or {},
        'arguments': arguments,
    }
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))


def _process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _run_cancel_case(executable, bottle, program, repo, isolated, output, redactor):
    ready_file = bottle / 'shim-ready.txt'
    capture_file = bottle / 'shim-capture.json'
    for file_path in (ready_file, capture_file):
        file_path.unlink(missing_ok=True)
    (bottle / 'shim-mode.txt').write_text('wait-cancel', encoding='utf-8')

    process = subprocess.Popen(
        [str(executable), 'run', '--bottle-path', '--ignore-saved-arguments', str(bottle), str(program)],
        cwd=repo, env=isolated, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    child_pid = None
    deadline = time.monotonic() + 8.0
    try:
        while time.monotonic() < deadline:
            if ready_file.is_file():
                raw_pid = ready_file.read_text(encoding='utf-8').strip()
                if raw_pid.isdigit():
                    child_pid = int(raw_pid)
                    break
            if process.poll() is not None:
                break
            time.sleep(0.05)

        if child_pid is not None and process.poll() is None:
            process.send_signal(signal.SIGINT)
        raw, _ = process.communicate(timeout=10)
        exit_code = process.returncode
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        raw, _ = process.communicate()
        exit_code = 124

    child_terminated = False
    if child_pid is not None:
        wait_deadline = time.monotonic() + 5.0
        while time.monotonic() < wait_deadline:
            if not _process_alive(child_pid):
                child_terminated = True
                break
            time.sleep(0.05)
        if not child_terminated:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except OSError:
                pass

    text = redactor(raw.decode('utf-8', errors='replace'))
    (output / 'run-cancel-sigint.log').write_text(text, encoding='utf-8')
    cancel_messages = localized_variants(repo, 'runtime.cli.cancelled', 'Launch cancelled.')
    diagnostic_ok = matches_any_localized(text, cancel_messages)
    return {
        'exitCode': exit_code,
        'expectedExitCode': 130,
        'childSpawned': child_pid is not None,
        'childTerminated': child_terminated,
        'diagnosticMatched': diagnostic_ok,
        'passed': exit_code == 130 and child_pid is not None and child_terminated and diagnostic_ok,
    }


def run_cli_checks(executable, repo, package, targets, directory, env, output, redactor):
    """Run isolated synthetic CLI run end-to-end checks."""
    home = pathlib.Path(directory) / 'synthetic-run-home'
    home.mkdir()
    isolated = dict(env, CFFIXED_USER_HOME=str(home))
    probe = (
        'import Foundation; import Darwin; '
        'let expected = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]; '
        'exit(FileManager.default.homeDirectoryForCurrentUser.path == expected ? 0 : 40)'
    )
    isolation = run_stage(
        'run-home-isolation',
        ['xcrun', 'swift', '-module-cache-path', str(pathlib.Path(directory) / 'run-module-cache'), '-e', probe],
        repo, isolated, output, redactor, 60,
    )
    if isolation['exitCode'] != 0:
        return {
            'passed': False,
            'status': 'environment_not_verified',
            'reason': 'synthetic Foundation home isolation was not established',
            'realWineExecuted': False,
        }

    identifiers = {target['buildSettings'].get('PRODUCT_BUNDLE_IDENTIFIER') for target in targets}
    for source in package.glob('Sources/**/Bundle+Extensions.swift'):
        identifiers.update(re.findall(r'Bundle\.main\.bundleIdentifier\s*\?\?\s*"([^"]+)"', source.read_text()))
    identifiers.discard(None)
    identifiers.discard('')
    if not identifiers:
        return {'passed': False, 'status': 'fixture_setup_failed', 'realWineExecuted': False}

    bottle = pathlib.Path(directory) / 'synthetic-run-bottle'
    drive_c = bottle / 'drive_c'
    drive_c.mkdir(parents=True)
    (bottle / 'Metadata.plist').write_bytes(plistlib.dumps({}))

    saved_program = drive_c / 'saved-args.exe'
    saved_program.write_bytes(b'inert synthetic program fixture; never executed by Wine\n')
    broken_saved_program = drive_c / 'broken-saved.exe'
    broken_saved_program.write_bytes(b'inert synthetic program fixture with broken saved args\n')

    _write_program_settings(
        bottle,
        'drive_c/saved-args.exe',
        arguments='"saved one" \'saved two\' ""',
        environment={'SYNTHETIC_ENV': 'hello world'},
    )
    _write_program_settings(
        bottle,
        'drive_c/broken-saved.exe',
        arguments="'unfinished quote",
    )

    registries = []
    shim_source = SHIM_SCRIPT.format(python=sys.executable)
    for identifier in sorted(identifiers):
        registry = home / 'Library/Containers' / identifier / 'BottleVM.plist'
        registry.parent.mkdir(parents=True, exist_ok=True)
        registries.append(registry)

        wine_bin = home / 'Library/Application Support' / identifier / 'Libraries/Wine/bin/wine64'
        wine_bin.parent.mkdir(parents=True, exist_ok=True)
        wine_bin.write_text(shim_source, encoding='utf-8')
        wine_bin.chmod(0o755)

    registry_encoder = (
        'import Foundation; '
        'struct V: Encodable { let major = 1; let minor = 0; let patch = 0; '
        'let preRelease = ""; let build = "" }; '
        'struct R: Encodable { let fileVersion = V(); let paths: [URL] }; '
        'let encoder = PropertyListEncoder(); encoder.outputFormat = .xml; '
        'let data = try encoder.encode(R(paths: [URL(fileURLWithPath: CommandLine.arguments[1])])); '
        'for path in CommandLine.arguments.dropFirst(2) { try data.write(to: URL(fileURLWithPath: path)) }'
    )
    encoded = run_stage(
        'run-fixture-registry',
        ['xcrun', 'swift', '-module-cache-path', str(pathlib.Path(directory) / 'run-module-cache'),
         '-e', registry_encoder, str(bottle), *map(str, registries)],
        repo, isolated, output, redactor, 60,
    )
    if encoded['exitCode'] != 0:
        return {'passed': False, 'status': 'fixture_setup_failed', 'realWineExecuted': False}

    capture_file = bottle / 'shim-capture.json'
    mode_file = bottle / 'shim-mode.txt'
    # CLI preserves the caller-supplied standardized path rather than resolving /var -> /private/var symlinks.
    expected_prefix = ['start', '/wait', '/unix', str(saved_program)]
    broken_prefix = ['start', '/wait', '/unix', str(broken_saved_program)]
    checks = {}

    def invoke(name, mode, cli_args):
        capture_file.unlink(missing_ok=True)
        mode_file.write_text(mode, encoding='utf-8')
        result = run_stage(name, [str(executable), 'run', '--bottle-path', *cli_args],
                           repo, isolated, output, redactor, 20)
        text = (output / (name + '.log')).read_text(encoding='utf-8')
        captured = json.loads(capture_file.read_text(encoding='utf-8')) if capture_file.is_file() else None
        return result, text, captured

    # 1. Default invocation inherits saved arguments and environment.
    res, _, cap = invoke('run-inherits-saved-arguments', 'exit-0', [str(bottle), str(saved_program)])
    expected_saved_argv = expected_prefix + ['saved one', 'saved two', '']
    checks['inheritsSavedArguments'] = {
        'exitCode': res['exitCode'],
        'expectedExitCode': 0,
        'argvMatched': cap is not None and cap.get('argv') == expected_saved_argv,
        'envMatched': cap is not None and cap.get('syntheticEnv') == 'hello world',
        'passed': res['exitCode'] == 0 and cap is not None
        and cap.get('argv') == expected_saved_argv and cap.get('syntheticEnv') == 'hello world',
    }

    # 2. --ignore-saved-arguments overrides saved arguments with an empty array (skipping malformed saved args).
    res, _, cap = invoke('run-ignore-saved-arguments-empty', 'exit-0',
                         ['--ignore-saved-arguments', str(bottle), str(broken_saved_program)])
    checks['ignoreSavedArgumentsEmptyOverride'] = {
        'exitCode': res['exitCode'],
        'expectedExitCode': 0,
        'argvMatched': cap is not None and cap.get('argv') == broken_prefix,
        'passed': res['exitCode'] == 0 and cap is not None and cap.get('argv') == broken_prefix,
    }

    # 3. Explicit arguments after -- replace saved values verbatim including empty string and dash-prefixed flags.
    explicit = ['two words', '', '--custom-flag=1']
    res, _, cap = invoke('run-explicit-arguments-override', 'exit-0',
                         [str(bottle), str(saved_program), '--', *explicit])
    checks['explicitArgumentsOverride'] = {
        'exitCode': res['exitCode'],
        'expectedExitCode': 0,
        'argvMatched': cap is not None and cap.get('argv') == expected_prefix + explicit,
        'passed': res['exitCode'] == 0 and cap is not None and cap.get('argv') == expected_prefix + explicit,
    }

    # 4. Non-zero child exit code propagates through RuntimeCLI.exitCode and localized message.
    res, text, _ = invoke('run-nonzero-exit', 'exit-42',
                          ['--ignore-saved-arguments', str(bottle), str(saved_program)])
    exit_variants = localized_variants(repo, 'runtime.issue.processExit', 'The program exited with code %d.', 42)
    diag_ok = matches_any_localized(text, exit_variants)
    checks['nonzeroExitMapping'] = {
        'exitCode': res['exitCode'],
        'expectedExitCode': 42,
        'diagnosticMatched': diag_ok,
        'passed': res['exitCode'] == 42 and diag_ok,
    }

    # 5. Signal termination (SIGTERM -> 128+15=143, SIGKILL -> 128+9=137).
    for label, mode, sig_num in (
        ('signalSigtermMapping', 'sigterm', signal.SIGTERM.value),
        ('signalSigkillMapping', 'sigkill', signal.SIGKILL.value),
    ):
        res, text, _ = invoke(f'run-{mode}', mode,
                              ['--ignore-saved-arguments', str(bottle), str(saved_program)])
        expected_code = 128 + sig_num
        sig_variants = localized_variants(
            repo, 'runtime.issue.processSignal', 'The program was terminated by signal %d.', sig_num
        )
        diag_ok = matches_any_localized(text, sig_variants)
        checks[label] = {
            'exitCode': res['exitCode'],
            'expectedExitCode': expected_code,
            'diagnosticMatched': diag_ok,
            'passed': res['exitCode'] == expected_code and diag_ok,
        }

    # 6. Cancellation via SIGINT returns 130, emits localized cancellation message, and terminates child.
    checks['cancelViaSigint'] = _run_cancel_case(
        executable, bottle, saved_program, repo, isolated, output, redactor
    )

    isolated_logs = list((home / 'Library/Logs').rglob('*.log')) if (home / 'Library/Logs').exists() else []
    all_passed = all(item['passed'] for item in checks.values())
    return {
        'passed': all_passed,
        'status': 'synthetic_cli_verified' if all_passed else 'failed',
        'homeIsolationVerified': True,
        'isolatedLogFilesCreated': len(isolated_logs),
        'checks': checks,
        'realWineExecuted': False,
        'realGuestExecuted': False,
        'realGameExecuted': False,
        'scope': 'isolated synthetic Wine shim in CFFIXED_USER_HOME exercising production CLI run end-to-end',
    }

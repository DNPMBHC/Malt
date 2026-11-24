import ipaddress
import stat
import tempfile
import secrets
#!/usr/bin/env python3
"""Private runtime discovery with sanitized diagnostic output for an isolated guest."""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = None
VM_ID = None
SCRIPTS = {}
PRIVATE_TOKENS = set()

def initialize():
    global ROOT, VM_ID, SCRIPTS
    try:
        ROOT = Path(__file__).resolve().parents[4]
        PRIVATE_TOKENS.add(ROOT.name)
        for item in ROOT.iterdir():
            if item.is_dir() and (item / '.git').exists():
                PRIVATE_TOKENS.add(item.name)
        for pattern in ('Modules/*', '*/Modules/*'):
            for item in ROOT.glob(pattern):
                if item.is_dir():
                    PRIVATE_TOKENS.add(item.name)
                    PRIVATE_TOKENS.add(item.name.replace('-', '_'))
                    PRIVATE_TOKENS.add(re.sub(r'[-_ ]', '', item.name))
        summary = ROOT / 'handoff/phase-2/evidence/window-a/summary.md'
        values = re.findall(r'(?i)\bUUID\s*:\s*[`{]?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})', summary.read_text())
        if len(set(value.lower() for value in values)) != 1:
            raise ValueError('The handoff must contain one consistent explicitly labeled VM UUID.')
        VM_ID = values[0]
        candidates = {path.resolve() for path in ROOT.glob('**/*GuestTransport.swift')}
        if len(candidates) != 1:
            raise ValueError('The private transport source is missing or ambiguous.')
        source = next(iter(candidates)).read_text()
        SCRIPTS = dict(re.findall(r'private static let (\w+) = #"""\n(.*?)\n\s*"""#', source, re.S))
        required = {'inspectScript', 'startScript', 'pushScript', 'executeScript', 'executeCapturingScript', 'capturedResultScript', 'resultScript'}
        if not required <= set(SCRIPTS):
            raise ValueError('The private transport source does not expose the required contract.')
    except (OSError, StopIteration, ValueError) as error:
        raise RuntimeError('Private Guest discovery failed safely: ' + redact(error)) from None

def redact(value):
    if isinstance(value, (dict, list)):
        return json.dumps(sanitize(value), ensure_ascii=False)
    if isinstance(value, str) and value.lstrip().startswith(('{', '[')):
        try:
            return json.dumps(sanitize(json.loads(value)), ensure_ascii=False)
        except (ValueError, TypeError):
            pass
    return redact_text(value)

def _private_output_key(key):
    normalized = re.sub(r'(?<=[a-z0-9])(?=[A-Z])', '_', str(key)).lower().replace('-', '_')
    if normalized.startswith('private_'):
        return True
    if normalized in {'pid', 'process_id', 'process_reference', 'vm_reference', 'vm_id', 'vm_uuid',
                      'uuid', 'username', 'user_name', 'hostname', 'computer_name', 'nonce'}:
        return True
    return bool(re.search(r'(?:^|_)(?:pid|pids|process_id|thread_id)$', normalized))


def sanitize(value):
    if isinstance(value, dict):
        return {redact_text(key): sanitize(child) for key, child in value.items() if not _private_output_key(key)}
    if isinstance(value, list):
        return [sanitize(child) for child in value]
    if isinstance(value, str):
        return redact(value)
    return value


def redact_text(value):
    text = str(value)
    if ROOT is not None:
        text = text.replace(str(ROOT), '[project-root]').replace(ROOT.name, 'my-project')
    for item in ('USER', 'LOGNAME'):
        private = os.environ.get(item, '')
        if private and len(private) > 2:
            text = re.sub(r'(?<![A-Za-z0-9])' + re.escape(private) + r'(?![A-Za-z0-9])', '[user]', text, flags=re.I)
    text = re.sub(r'(?:\\*/)(?:Users|Volumes|home)(?:\\*/)[^\r\n\s\"\x27`<>;,]+', '[private-path]', text)
    text = re.sub(r'(?i)(?<![A-Z0-9])[A-Z]:(?:\\+|/)[^\r\n\"\x27<>;,]*', '[guest-path]', text)
    text = re.sub(r'\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b', '[identifier]', text)
    def hide_valid_ipv4(match):
        try:
            ipaddress.IPv4Address(match.group())
        except ipaddress.AddressValueError:
            return match.group()
        return '[network-address]'
    text = re.sub(r'(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])', hide_valid_ipv4, text)
    text = re.sub(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}', '[email]', text)
    for token in sorted(PRIVATE_TOKENS, key=len, reverse=True):
        if token and token not in {'my-project', 'module-x', 'feature-y'}:
            text = re.sub(re.escape(token) + r'(?:Kit|Cmd|App|Wine)?', 'module-x', text, flags=re.I)
    return text


def apple(name, args, timeout=45, vm_reference=None):
    if not SCRIPTS:
        initialize()
    result = subprocess.run(['osascript', '-e', SCRIPTS[name], '--', vm_reference or VM_ID, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(redact(result.stderr or result.stdout))
    return result.stdout.rstrip('\n')

def _recovery_directory():
    path = Path(tempfile.gettempdir()) / 'b2-private-executions'
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    details = path.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid():
        raise RuntimeError('Private recovery directory is unavailable.')
    os.chmod(path, 0o700)
    return path


def _save_private_execution(process, vm_reference, kind, response_marker=None):
    directory = _recovery_directory()
    name = secrets.token_hex(16) + '.json'
    descriptor = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump({'schema_version': '1.1.0', 'process_reference': process,
                       'vm_reference': vm_reference, 'kind': kind,
                       'private_response_marker': response_marker,
                       'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}, stream)
    except Exception:
        raise RuntimeError('Private recovery state could not be written.') from None
    return directory / name


def _forget_private_execution(handle):
    try:
        handle.unlink()
    except FileNotFoundError:
        pass


def _read_private_execution(handle):
    descriptor = os.open(handle, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r', encoding='utf-8') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise RuntimeError('Private execution state is not a regular file.')
        value = json.load(stream)
    if value.get('schema_version') not in {'1.0.0', '1.1.0'} or not value.get('process_reference') or not value.get('vm_reference'):
        raise RuntimeError('Private execution state is incomplete.')
    return value


def _captured_fields(process, timeout=10, vm_reference=None):
    raw = apple('capturedResultScript', [process], timeout=timeout, vm_reference=vm_reference)
    fields = raw.split('\n', 4)
    if not fields or fields[0] not in {'0', '1'}:
        raise RuntimeError('Guest execution status is invalid.')
    return fields


def _bound_completed_response(fields, response_marker):
    if not isinstance(response_marker, str) or not re.fullmatch(r'[0-9a-f]{64}', response_marker):
        raise RuntimeError('Guest response identity is unavailable.')
    if len(fields) < 4 or fields[0] != '1':
        raise RuntimeError('Guest completion is unavailable.')
    output = base64.b64decode(fields[3], validate=True).decode('utf-8', errors='replace')
    frame = '\x1eB2_RESPONSE_MARKER:' + response_marker + '\x1f'
    if output.count(frame) != 1 or output.count('\x1eB2_RESPONSE_MARKER:') != 1:
        raise RuntimeError('Guest response identity could not be verified.')
    return {'exit_code': int(fields[1]), 'signal': int(fields[2]),
            'stdout': output.replace(frame, '', 1),
            'response_marker_verified': True, 'recovery_pending': False}


def _cleanup_current_execution(process, handle, grace=10):
    # A transport reference can be a reused native PID. Without a separately
    # verified native creation time, no process termination is authorized here.
    try:
        value = _read_private_execution(handle)
        if str(process) != str(value['process_reference']):
            raise RuntimeError('Private execution reference mismatch.')
        fields = _captured_fields(process, timeout=5, vm_reference=value['vm_reference'])
        if fields[0] == '1':
            _bound_completed_response(fields, value.get('private_response_marker'))
            _forget_private_execution(handle)
            return 'bound_target_exit_confirmed', False
    except Exception:
        pass
    return 'exit_unconfirmed_no_process_termination', True


def guest(executable, arguments, timeout=55, response_marker=None):
    if not isinstance(response_marker, str) or not re.fullmatch(r'[0-9a-f]{64}', response_marker):
        return {'status': 'execution_identity_unavailable', 'exit_code': 1,
                'signal': 0, 'stdout': '', 'recovery_pending': False,
                'reason': 'A private completion marker is required before launching.'}
    process = apple('executeCapturingScript', [executable, len(arguments), *arguments])
    handle = _save_private_execution(process, VM_ID, 'captured', response_marker)
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            fields = _captured_fields(process, timeout=max(1, min(10, deadline-time.monotonic())))
            if fields[0] == '1':
                result = _bound_completed_response(fields, response_marker)
                _forget_private_execution(handle)
                return result
            time.sleep(0.75)
    except Exception:
        cleanup, pending = _cleanup_current_execution(process, handle)
        return {'status': 'execution_error', 'exit_code': 1, 'signal': 0, 'stdout': '',
                'cleanup': cleanup, 'recovery_pending': pending,
                'reason': 'Execution failed; unconfirmed processes retain private recovery state.'}
    cleanup, pending = _cleanup_current_execution(process, handle)
    return {'status': 'timeout', 'exit_code': 124, 'signal': 0, 'stdout': '',
            'cleanup': cleanup, 'recovery_pending': pending,
            'reason': 'Timed-out execution remains tracked until exit is confirmed.'}


def recover_private_executions(timeout=30):
    # Only a matching private response marker binds a completed result. Legacy
    # unmarked/cleanup handles stay pending; native PID status proves no identity.
    handles = list(_recovery_directory().glob('*.json'))
    deadline = time.monotonic() + max(0, timeout)
    completed = 0
    pending = set(handles)
    while pending and time.monotonic() < deadline:
        progressed = False
        for handle in list(pending):
            if time.monotonic() >= deadline:
                break
            try:
                value = _read_private_execution(handle)
                marker = value.get('private_response_marker')
                if value.get('kind') != 'captured' or not isinstance(marker, str) or not re.fullmatch(r'[0-9a-f]{64}', marker):
                    continue
                fields = _captured_fields(value['process_reference'],
                                          timeout=max(1, min(5, deadline-time.monotonic())), vm_reference=value['vm_reference'])
                if fields and fields[0] == '1':
                    _bound_completed_response(fields, marker)
                    _forget_private_execution(handle)
                    pending.remove(handle)
                    completed += 1
                    progressed = True
            except Exception:
                continue
        if pending and not progressed:
            time.sleep(min(0.5, max(0, deadline-time.monotonic())))
    return {'status': 'recovery_pending' if pending else 'recovered',
            'exit_code': 124 if pending else 0, 'recovery_pending': bool(pending),
            'completed_execution_count': completed, 'pending_execution_count': len(pending),
            'reason': 'Only neutral recovery counts are exported; execution references stay private.'}


def powershell(text, timeout=55, label='guest-command'):
    if ROOT is None or not SCRIPTS:
        initialize()
    marker = secrets.token_hex(32)
    wrapped = ("$b2RequestSucceeded = $true\ntry {\n& {\n" + text +
               "\n}\n$b2RequestSucceeded = $?\n} finally {\n" +
               "[Console]::Out.Write(([string]([char]30)) + 'B2_RESPONSE_MARKER:" + marker +
               "' + ([string]([char]31)))\n}\nif (-not $b2RequestSucceeded) { exit 1 }\n")
    encoded = base64.b64encode(wrapped.encode('utf-16le')).decode()
    record_operation(label, 'started')
    try:
        result = guest('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], timeout, response_marker=marker)
        record_operation(label, 'ended', {'exit_code': result.get('exit_code'), 'signal': result.get('signal'), 'status': result.get('status', 'exited')})
        return result
    except Exception:
        record_operation(label, 'failed')
        raise

def record_operation(label, state, extra=None):
    entry = {'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'operation': label, 'state': state}
    if extra:
        entry.update(extra)
    path = ROOT / 'handoff/phase-2/evidence/window-b/b2-guest-operation-log.jsonl'
    with path.open('a') as output:
        output.write(redact(json.dumps(entry, ensure_ascii=False)) + '\n')

def main():
    initialize()
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['inspect', 'start', 'ps', 'ps-file', 'push', 'poll', 'recover'])
    parser.add_argument('arguments', nargs='*')
    parser.add_argument('--timeout', type=int, default=55)
    args = parser.parse_args()
    if args.operation == 'recover':
        result = recover_private_executions(args.timeout)
    elif args.operation == 'inspect':
        values = apple('inspectScript', []).splitlines()
        result = dict(zip(['private_vm_reference', 'backend', 'status', 'architecture'], values))
        result.pop('private_vm_reference', None)
    elif args.operation == 'start':
        result = {'result': apple('startScript', [])}
    elif args.operation in ('ps', 'ps-file'):
        code = args.arguments[0] if args.operation == 'ps' else Path(args.arguments[0]).read_text()
        result = powershell(code, args.timeout)
        result.pop('private_process_reference', None)
    elif args.operation == 'push':
        local = Path(args.arguments[0]).resolve()
        result = {'result': apple('pushScript', [args.arguments[1], str(local)])}
    else:
        result = {'status': 'unbound_poll_rejected', 'exit_code': 1,
                  'reason': 'Raw process polling has no verified response identity; use private recovery state.'}
    print(redact(json.dumps(result, ensure_ascii=False)))
    if result.get('status') == 'timeout':
        sys.exit(124)
    if result.get('exit_code', 0) != 0 or result.get('signal', 0) != 0:
        sys.exit(1)
    if 'stdout' in result:
        try:
            payload = json.loads(result['stdout'])
        except (ValueError, TypeError):
            payload = None
        if isinstance(payload, dict) and payload.get('native_exit_code', 0) != 0:
            sys.exit(1)

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'status': 'failed', 'error': redact(error)}, ensure_ascii=False))
        sys.exit(1)

#!/usr/bin/env python3
"""Run an authorized isolated Guest stage and persist only sanitized evidence."""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).absolute().parent
safety = None


def load_safety():
    spec = importlib.util.spec_from_file_location('b2_stage_export_safety', HERE / 'b2-export-safety.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    required = ('load_local', 'completion_error', 'require_completed', 'checked_export', 'atomic_write', 'public_failure')
    if not all(callable(getattr(module, name, None)) for name in required) or not isinstance(getattr(module, 'PublicFailure', None), type):
        raise ValueError('The local export safety contract is unavailable.')
    return module


def load_control():
    return safety.load_local('b2_stage_guest_control', 'b2-guest-control.py')


def failure_result(error):
    fallback = 'local_export_safety_unavailable' if safety is None else 'stage_execution_failed_safely'
    try:
        if safety is not None and isinstance(error, safety.PublicFailure):
            if isinstance(error.reason, str) and re.fullmatch(r'[a-z_]{1,80}', error.reason) and type(error.exit_code) is int and error.exit_code in (1, 124):
                return {'status': 'failed', 'reason': error.reason}, error.exit_code
    except Exception:
        pass
    return {'status': 'failed', 'reason': fallback}, 1


def payload_error(result, require_json=False):
    try:
        payload = json.loads(result.get('stdout', ''))
    except (ValueError, TypeError):
        return safety.PublicFailure('invalid_required_stage_json') if require_json else None
    if isinstance(payload, dict):
        if 'native_exit_code' in payload:
            code = payload['native_exit_code']
            if type(code) is not int or code != 0:
                return safety.PublicFailure('stage_native_exit_failed')
        if payload.get('status') in {'failed', 'error', 'execution_error', 'timeout'}:
            return safety.PublicFailure('stage_reported_failure', 124 if payload['status'] == 'timeout' else 1)
    return None


def main(argv=None):
    global safety
    try:
        if safety is None:
            safety = load_safety()
        parser = argparse.ArgumentParser()
        parser.add_argument('stage')
        parser.add_argument('source_file')
        parser.add_argument('--timeout', type=int, default=55)
        parser.add_argument('--summary', action='store_true')
        parser.add_argument('--guest-identities', action='store_true')
        parser.add_argument('--require-json', action='store_true')
        args = parser.parse_args(argv)
        if not re.fullmatch(r'[a-z0-9-]{1,48}', args.stage):
            raise safety.PublicFailure('invalid_neutral_stage_alias')
        if not 1 <= args.timeout <= 3600:
            raise safety.PublicFailure('stage_timeout_out_of_bounds')
        source_bytes = Path(args.source_file).read_bytes()
        source = source_bytes.decode('utf-8-sig')
        control = load_control()
        control.initialize()
        if args.guest_identities:
            identity = control.powershell('[pscustomobject]@{a=$env:COMPUTERNAME;b=(Get-CimInstance Win32_ComputerSystem).UserName} | ConvertTo-Json -Compress', 10, label='private-output-token-preparation')
            safety.require_completed(identity)
            values = json.loads(identity['stdout'])
            if not isinstance(values, dict) or not isinstance(values.get('a'), str) or not values['a'] or any(value is not None and not isinstance(value, str) for value in values.values()):
                raise safety.PublicFailure('invalid_private_identity_preparation')
            for value in values.values():
                if value:
                    control.PRIVATE_TOKENS.update(str(value).split(chr(92)))
        code = "try { & {\n" + source + "\n} } catch { [pscustomobject]@{stage='" + args.stage + "';native_exit_code=1;error=$_.Exception.Message} | ConvertTo-Json -Compress; exit 1 }"
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result = control.powershell(code, args.timeout, label=args.stage)
        outcome = safety.completion_error(result)
        if not isinstance(result, dict):
            raise outcome
        result = dict(result)
        if outcome is not None and outcome.reason in {'transport_output_truncated', 'invalid_transport_stdout'}:
            result['stdout'] = ''
            result['output_discarded_due_to_transport_validation'] = True
        if outcome is None:
            outcome = payload_error(result, args.require_json)
        if outcome is not None and outcome.reason == 'invalid_required_stage_json':
            result['stdout'] = ''
            result['output_discarded_due_to_json_validation'] = True
        result.update(stage=args.stage, started_at_utc=started, ended_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), stage_source_sha256=hashlib.sha256(source_bytes).hexdigest(), wrapper_validation_status='failed' if outcome else 'passed')
        if outcome:
            result['wrapper_validation_reason'] = outcome.reason
        safe, content = safety.checked_export(control, result)
        safety.atomic_write(HERE / ('b2-' + args.stage + '-result.json'), content)
        if args.summary:
            summary = {key: value for key, value in safe.items() if key != 'stdout'}
            try:
                payload = json.loads(safe.get('stdout', '{}'))
                if not isinstance(payload, dict):
                    raise TypeError('A structured capture is required for the summary.')
                summary['capture'] = {key: payload[key] for key in ('stage', 'status', 'coverage', 'loaded_image_enumeration', 'reason', 'exception_type', 'script_line') if key in payload}
                for key in ('binaries', 'services', 'events'):
                    if isinstance(payload.get(key), list):
                        summary[key + '_count'] = len(payload[key])
            except (ValueError, TypeError):
                summary['capture'] = 'Stored sanitized output.'
            print(json.dumps(summary, ensure_ascii=False, allow_nan=False))
        else:
            print(content.decode('utf-8').rstrip())
        return outcome.exit_code if outcome else 0
    except Exception as error:
        failure, exit_code = failure_result(error)
        print(json.dumps(failure))
        return exit_code


if __name__ == '__main__':
    sys.exit(main())

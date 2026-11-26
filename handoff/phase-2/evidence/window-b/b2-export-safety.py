#!/usr/bin/env python3
"""Shared local export checks; importing this module never calls the Guest."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile

HERE = Path(__file__).absolute().parent
TRUNCATION_KEYS = {'truncated', 'stdout_truncated', 'stderr_truncated',
                   'out_truncated', 'err_truncated', 'out-truncated', 'err-truncated'}


class PublicFailure(ValueError):
    def __init__(self, reason, exit_code=1):
        super().__init__(reason)
        self.reason = reason
        self.exit_code = exit_code


def load_local(name, leaf):
    spec = importlib.util.spec_from_file_location(name, HERE / leaf)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def completion_error(result):
    if not isinstance(result, dict):
        return PublicFailure('invalid_transport_result')
    if result.get('status') == 'timeout':
        return PublicFailure('transport_timeout', 124)
    if result.get('recovery_pending'):
        return PublicFailure('transport_recovery_pending', 124)
    for key in TRUNCATION_KEYS:
        if key in result and result[key] is not False:
            return PublicFailure('transport_output_truncated')
    if result.get('status') not in {None, 'exited', 'completed', 'captured', 'ok', 'success'}:
        return PublicFailure('transport_status_failed')
    if type(result.get('exit_code')) is not int or type(result.get('signal', 0)) is not int:
        return PublicFailure('invalid_transport_exit_status')
    if result['exit_code'] != 0 or result.get('signal', 0) != 0:
        return PublicFailure('transport_nonzero_exit_or_signal')
    if not isinstance(result.get('stdout'), str):
        return PublicFailure('invalid_transport_stdout')
    return None


def require_completed(result):
    error = completion_error(result)
    if error is not None:
        raise error
    return result


def checked_export(control, value):
    safe = control.sanitize(value)
    guard = load_local('b2_export_privacy_guard', 'b2-evidence-tools.py')
    tokens = guard.runtime_private_tokens()
    tokens.update(str(token).casefold() for token in control.PRIVATE_TOKENS
                  if len(str(token)) >= 3 and token not in {'my-project', 'module-x', 'feature-y'})

    def audit(child, depth=0):
        if depth > 32:
            raise PublicFailure('export_nested_json_limit')
        if guard.json_privacy_categories(child, tokens):
            raise PublicFailure('export_privacy_check_failed')
        if isinstance(child, dict):
            for nested in child.values():
                audit(nested, depth + 1)
        elif isinstance(child, list):
            for nested in child:
                audit(nested, depth + 1)
        elif isinstance(child, str) and child.lstrip().startswith(('{', '[')):
            try:
                nested = json.loads(child)
            except (ValueError, TypeError):
                return
            audit(nested, depth + 1)

    audit(safe)
    content = (json.dumps(safe, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
    if guard.text_privacy_categories(content.decode('utf-8'), tokens):
        raise PublicFailure('export_privacy_check_failed')
    return safe, content


def atomic_write(target, content):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='b2-neutral-', suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def public_failure(error, fallback):
    if isinstance(error, PublicFailure):
        return {'status': 'failed', 'reason': error.reason}, error.exit_code
    return {'status': 'failed', 'reason': fallback, 'exception_type': type(error).__name__}, 1

#!/usr/bin/env python3
"""Read a neutral Guest JSON evidence file in bounded chunks and sanitize it."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).absolute().parent
CHUNK_BYTES = 12000
MAX_SOURCE_BYTES = 16000000
safety = None


def load_safety():
    spec = importlib.util.spec_from_file_location('b2_pull_export_safety', HERE / 'b2-export-safety.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    required = ('load_local', 'completion_error', 'require_completed', 'checked_export', 'atomic_write', 'public_failure')
    if not all(callable(getattr(module, name, None)) for name in required) or not isinstance(getattr(module, 'PublicFailure', None), type):
        raise ValueError('The local export safety contract is unavailable.')
    return module


def load_control():
    return safety.load_local('b2_pull_guest_control', 'b2-guest-control.py')


def failure_result(error):
    fallback = 'local_export_safety_unavailable' if safety is None else 'evidence_transfer_failed_safely'
    try:
        if safety is not None and isinstance(error, safety.PublicFailure):
            if isinstance(error.reason, str) and re.fullmatch(r'[a-z_]{1,80}', error.reason) and type(error.exit_code) is int and error.exit_code in (1, 124):
                return {'status': 'failed', 'reason': error.reason}, error.exit_code
    except Exception:
        pass
    return {'status': 'failed', 'reason': fallback}, 1


def read_metadata(control, path_code):
    result = control.powershell(path_code + "[pscustomobject]@{size=(Get-Item $path).Length;sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json -Compress", 20, label='evidence-file-metadata')
    safety.require_completed(result)
    try:
        metadata = json.loads(result['stdout'])
    except (ValueError, TypeError):
        raise safety.PublicFailure('invalid_source_metadata_json') from None
    if not isinstance(metadata, dict) or type(metadata.get('size')) is not int:
        raise safety.PublicFailure('invalid_source_size')
    if not 0 <= metadata['size'] <= MAX_SOURCE_BYTES:
        raise safety.PublicFailure('source_size_out_of_bounds')
    digest = metadata.get('sha256')
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', digest):
        raise safety.PublicFailure('invalid_source_hash')
    return {'size': metadata['size'], 'sha256': digest.lower()}


def main(argv=None):
    global safety
    try:
        if safety is None:
            safety = load_safety()
        parser = argparse.ArgumentParser()
        parser.add_argument('guest_leaf')
        parser.add_argument('artifact_alias')
        args = parser.parse_args(argv)
        if any(not re.fullmatch(r'[a-z0-9-]{1,64}\.json', value) for value in (args.guest_leaf, args.artifact_alias)):
            raise safety.PublicFailure('invalid_neutral_artifact_leaf')
        control = load_control()
        control.initialize()
        path_code = "$path=Join-Path (Join-Path $env:SystemDrive 'lab-b2') '" + args.guest_leaf + "'; "
        metadata = read_metadata(control, path_code)
        data = bytearray()
        chunks = 0
        while len(data) < metadata['size']:
            count = min(CHUNK_BYTES, metadata['size'] - len(data))
            code = path_code + "$stream=[IO.File]::OpenRead($path); try {$null=$stream.Seek(" + str(len(data)) + ",[IO.SeekOrigin]::Begin);$bytes=[byte[]]::new(" + str(count) + ");$read=$stream.Read($bytes,0,$bytes.Length);[Convert]::ToBase64String($bytes,0,$read)} finally {$stream.Dispose()}"
            result = control.powershell(code, 20, label='bounded-evidence-read')
            safety.require_completed(result)
            encoded = result['stdout'].strip()
            if len(encoded) > 4 * ((count + 2) // 3):
                raise safety.PublicFailure('source_chunk_exceeds_requested_size')
            try:
                chunk = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                raise safety.PublicFailure('invalid_source_chunk_encoding') from None
            if not chunk:
                raise safety.PublicFailure('source_ended_before_recorded_size')
            if len(chunk) > count:
                raise safety.PublicFailure('source_chunk_exceeds_requested_size')
            data.extend(chunk)
            chunks += 1
        if hashlib.sha256(data).hexdigest() != metadata['sha256']:
            raise safety.PublicFailure('source_hash_mismatch_during_transfer')
        if read_metadata(control, path_code) != metadata:
            raise safety.PublicFailure('source_changed_after_transfer')
        try:
            payload = json.loads(data.decode('utf-8-sig'))
        except (ValueError, UnicodeError):
            raise safety.PublicFailure('invalid_source_json') from None
        _, content = safety.checked_export(control, payload)
        safety.atomic_write(HERE / args.artifact_alias, content)
        print(json.dumps({'artifact_alias': args.artifact_alias, 'source_sha256': metadata['sha256'], 'sanitized_sha256': hashlib.sha256(content).hexdigest(), 'source_size_bytes': len(data), 'sanitized_size_bytes': len(content), 'chunks': chunks, 'privacy': 'sanitized_and_verified_before_export'}))
        return 0
    except Exception as error:
        failure, exit_code = failure_result(error)
        print(json.dumps(failure))
        return exit_code


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Validate Phase 2 real-environment evidence artifacts and enforce SHA-256 bindings."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re


SHA256_RE = re.compile(r'^[0-9a-f]{64}$')
UNREDACTED_HOME_RE = re.compile(r'/Users/[^/\s"\']+')
WINDOWS = ('window-a', 'window-b', 'window-c')
REAL_EXECUTION_KEYS = (
    'realGuestExecuted',
    'realDriverLoaded',
    'realWineExecuted',
    'realGameExecuted',
    'realBenchmarkExecuted',
)


SOURCE_KEY_SUFFIXES = (
    '_py', '.py', '_cpp', '.cpp', '_cc', '.cc', '_c', '.c', '_h', '.h',
    '_swift', '.swift', '_sh', '.sh', '_m', '.m', '_mm', '.mm',
)
BINARY_KEY_SUFFIXES = (
    '_exe', '.exe', '_dll', '.dll', '_sys', '.sys', '_dylib', '.dylib',
    '_so', '.so', '_app', '.app', '_bin',
)
BINARY_EXACT_KEYS = {'wine', 'wine64', 'binary', 'executable', 'metal_host', 'probe_binary'}


def is_valid_sha256_binding(value) -> bool:
    """Accept either a single 64-hex SHA-256 string or a non-empty mapping of 64-hex SHA-256 values."""
    if isinstance(value, str):
        return bool(SHA256_RE.fullmatch(value))
    if isinstance(value, dict) and value:
        return all(
            isinstance(key, str) and bool(key.strip()) and isinstance(digest_val, str)
            and bool(SHA256_RE.fullmatch(digest_val))
            for key, digest_val in value.items()
        )
    return False


def extract_digest_bindings(payload: dict):
    """Extract source and binary SHA-256 bindings from top-level fields or an immutable_digests map."""
    source_binding = payload.get('sourceSHA256', payload.get('source_sha256'))
    binary_binding = payload.get('binarySHA256', payload.get('binary_sha256'))
    if source_binding is not None or binary_binding is not None:
        return source_binding, binary_binding

    combined = payload.get('immutable_digests', payload.get('immutableDigests'))
    if not isinstance(combined, dict) or not combined:
        return None, None
    if not is_valid_sha256_binding(combined):
        return None, None

    source_map = {}
    binary_map = {}
    for key, val in combined.items():
        lower = key.lower()
        if lower.endswith(SOURCE_KEY_SUFFIXES) or 'source' in lower:
            source_map[key] = val
        if lower.endswith(BINARY_KEY_SUFFIXES) or lower in BINARY_EXACT_KEYS or 'binary' in lower:
            binary_map[key] = val
    return (source_map or None), (binary_map or None)


def requires_immutable_digest_binding(payload: dict) -> bool:
    """Determine whether a JSON artifact claims real execution or performance measurement."""
    schema = str(payload.get('schema', '')).lower()
    kind = str(payload.get('kind', payload.get('evidenceType', ''))).lower()
    if any(token in schema for token in ('performance-sample', 'phase2-real', 'guest-run', 'wdk-probe', 'wine-bench')):
        return True
    if any(token in kind for token in ('real-guest', 'real-wdk', 'real-wine', 'real-performance', 'benchmark')):
        return True
    for key in REAL_EXECUTION_KEYS:
        val = payload.get(key)
        if val is True or (isinstance(val, str) and val.lower() in {'passed', 'verified', 'executed', 'true'}):
            return True
    if isinstance(payload.get('runs'), list) and payload['runs']:
        return True
    return False


def validate_evidence_file(path: pathlib.Path, evidence_root: pathlib.Path) -> dict:
    """Validate one JSON evidence artifact under handoff/phase-2/evidence/."""
    rel = str(path.relative_to(evidence_root))
    raw_bytes = path.read_bytes()
    file_sha256 = hashlib.sha256(raw_bytes).hexdigest()
    raw_text = raw_bytes.decode('utf-8', errors='replace')
    errors = []

    if UNREDACTED_HOME_RE.search(raw_text):
        errors.append('unredacted_home_path_detected')

    try:
        payload = json.loads(raw_text)
    except ValueError:
        return {
            'file': rel,
            'fileSHA256': file_sha256,
            'requiresDigestBinding': True,
            'passed': False,
            'errors': ['invalid_json', *errors],
        }

    if not isinstance(payload, dict):
        return {
            'file': rel,
            'fileSHA256': file_sha256,
            'requiresDigestBinding': False,
            'passed': False,
            'errors': ['json_object_required', *errors],
        }

    needs_binding = requires_immutable_digest_binding(payload)
    source_binding, binary_binding = extract_digest_bindings(payload)

    if needs_binding:
        if not is_valid_sha256_binding(source_binding):
            errors.append('missing_or_invalid_sourceSHA256')
        if not is_valid_sha256_binding(binary_binding):
            errors.append('missing_or_invalid_binarySHA256')

    return {
        'file': rel,
        'fileSHA256': file_sha256,
        'schema': payload.get('schema'),
        'requiresDigestBinding': needs_binding,
        'hasValidSourceSHA256': is_valid_sha256_binding(source_binding),
        'hasValidBinarySHA256': is_valid_sha256_binding(binary_binding),
        'passed': not errors,
        'errors': errors,
    }


def validate_phase2_evidence(evidence_root: pathlib.Path) -> dict:
    """Scan window-{a,b,c} evidence folders and enforce Phase 2 validation rules."""
    windows = {}
    proposals = []
    all_passed = True
    any_real_evidence = False
    completed_windows = 0

    for window in WINDOWS:
        folder = evidence_root / window
        proposal = folder / 'interface-proposal.md'
        if proposal.is_file():
            proposals.append(str(proposal.relative_to(evidence_root)))

        if not folder.is_dir():
            windows[window] = {
                'status': 'pending_real_evidence',
                'artifactCount': 0,
                'realExecutionArtifacts': 0,
                'artifacts': [],
                'passed': True,
            }
            continue

        json_files = sorted(
            path for path in folder.rglob('*.json')
            if not path.name.endswith('.template.json')
        )
        artifacts = [validate_evidence_file(path, evidence_root) for path in json_files]
        real_artifacts = [item for item in artifacts if item['requiresDigestBinding']]
        window_passed = all(item['passed'] for item in artifacts)
        all_passed = all_passed and window_passed
        if real_artifacts:
            any_real_evidence = True
        if real_artifacts and window_passed:
            status = 'real_evidence_validated'
            completed_windows += 1
        elif artifacts and not window_passed:
            status = 'invalid_evidence'
        else:
            status = 'pending_real_evidence'

        windows[window] = {
            'status': status,
            'artifactCount': len(artifacts),
            'realExecutionArtifacts': len(real_artifacts),
            'artifacts': artifacts,
            'passed': window_passed,
        }

    return {
        'schema': 'task-07-phase2-evidence-v1',
        'passed': all_passed,
        'windows': windows,
        'interfaceProposals': proposals,
        'anyRealEvidencePresent': any_real_evidence,
        'allWindowsHaveRealEvidence': completed_windows == len(WINDOWS),
        'completedWindowCount': completed_windows,
        'expectedWindowCount': len(WINDOWS),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    task = pathlib.Path(__file__).resolve().parent
    root = task.parents[1]
    parser.add_argument('--evidence-root', type=pathlib.Path, default=root / 'handoff/phase-2/evidence')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    report = validate_phase2_evidence(args.evidence_root.resolve())
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized, encoding='utf-8')
    print(serialized, end='')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

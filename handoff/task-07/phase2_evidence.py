#!/usr/bin/env python3
"""Validate Phase 2 real-environment evidence artifacts and verify real SHA-256 file digests."""

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
    '_py', '.py', '_cpp', '.cpp', '_cc', '.cc', '_c', '.c', '_h', '.h', '_hpp', '.hpp',
    '_swift', '.swift', '_sh', '.sh', '_m', '.m', '_mm', '.mm', '_ps1', '.ps1',
)
BINARY_KEY_SUFFIXES = (
    '_exe', '.exe', '_dll', '.dll', '_sys', '.sys', '_dylib', '.dylib',
    '_so', '.so', '_app', '.app', '_bin',
)
BINARY_EXACT_KEYS = {'wine', 'wine64', 'binary', 'executable', 'metal_host', 'probe_binary'}
FILE_EXT_RE = re.compile(r'\.[a-z0-9]{1,8}$', re.IGNORECASE)


def sha256_file(path: pathlib.Path) -> str:
    """Compute SHA-256 hex digest by reading raw file bytes."""
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


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
    """Extract source and binary SHA-256 bindings from top-level fields or digest maps."""
    source_binding = payload.get('sourceSHA256', payload.get('source_sha256'))
    binary_binding = payload.get('binarySHA256', payload.get('binary_sha256'))
    if source_binding is not None or binary_binding is not None:
        return source_binding, binary_binding

    combined = payload.get(
        'immutable_digests',
        payload.get('immutableDigests', payload.get('source_digests', payload.get('digests'))),
    )
    if isinstance(combined, dict) and combined and is_valid_sha256_binding(combined):
        return _split_source_and_binary_digests(combined)

    for artifact_map_key in ('input_artifacts', 'inputs'):
        artifact_map = payload.get(artifact_map_key)
        if not isinstance(artifact_map, dict) or not artifact_map:
            continue
        flat_map = {}
        for key, item in artifact_map.items():
            if isinstance(item, dict) and isinstance(item.get('sha256'), str):
                flat_map[key] = item['sha256']
            elif isinstance(item, str):
                flat_map[key] = item
        if flat_map and is_valid_sha256_binding(flat_map):
            return _split_source_and_binary_digests(flat_map)

    return None, None


def _split_source_and_binary_digests(combined: dict):
    source_map = {}
    binary_map = {}
    for key, val in combined.items():
        lower = key.lower()
        if lower.endswith(SOURCE_KEY_SUFFIXES) or 'source' in lower:
            source_map[key] = val
        if lower.endswith(BINARY_KEY_SUFFIXES) or lower in BINARY_EXACT_KEYS or 'binary' in lower:
            binary_map[key] = val
    return (source_map or None), (binary_map or None)


def _is_within(child: pathlib.Path, parent: pathlib.Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _resolve_evidence_or_workspace_path(
    reference: str,
    artifact_path: pathlib.Path,
    window_dir: pathlib.Path,
    evidence_root: pathlib.Path,
    repo_root: pathlib.Path | None,
) -> tuple[pathlib.Path | None, str]:
    """Resolve a declared relative file path inside evidence_root first, then repo_root."""
    cleaned = reference.strip()
    if not cleaned or cleaned.startswith('/') or '\\' in cleaned or '..' in pathlib.PurePosixPath(cleaned).parts:
        return None, 'external'

    for base in (artifact_path.parent, window_dir, evidence_root):
        candidate = base / cleaned
        if candidate.is_file() and _is_within(candidate, evidence_root):
            return candidate, 'evidence'

    if repo_root is not None:
        candidate = repo_root / cleaned
        if candidate.is_file() and _is_within(candidate, repo_root):
            return candidate, 'workspace'

    return None, 'unresolved'


def _collect_declared_file_digests(payload: dict) -> list[tuple[str, str, bool]]:
    """Return list of (reference, expected_sha256, require_local_file) declared by an artifact."""
    entries: list[tuple[str, str, bool]] = []

    for field in ('sourceSHA256', 'source_sha256', 'binarySHA256', 'binary_sha256',
                  'immutable_digests', 'immutableDigests', 'source_digests', 'digests'):
        mapping = payload.get(field)
        if isinstance(mapping, dict):
            for key, val in mapping.items():
                if isinstance(key, str) and isinstance(val, str) and SHA256_RE.fullmatch(val):
                    entries.append((key, val, False))

    for artifact_map_key in ('input_artifacts', 'inputs'):
        artifact_map = payload.get(artifact_map_key)
        if isinstance(artifact_map, dict):
            for item in artifact_map.values():
                if not isinstance(item, dict):
                    continue
                ref = item.get('file', item.get('path'))
                digest = item.get('sha256')
                if isinstance(ref, str) and ref and isinstance(digest, str) and SHA256_RE.fullmatch(digest):
                    entries.append((ref, digest, True))

    for list_field in ('sourceFiles', 'artifacts'):
        items = payload.get(list_field)
        if isinstance(items, list):
            for item in items:
                if not isinstance(item, dict):
                    continue
                ref = item.get('logicalPath', item.get('path'))
                digest = item.get('sha256')
                if isinstance(ref, str) and isinstance(digest, str) and SHA256_RE.fullmatch(digest):
                    entries.append((ref, digest, False))

    runs = payload.get('runs')
    if isinstance(runs, list):
        for run in runs:
            if not isinstance(run, dict):
                continue
            files = run.get('files')
            if not isinstance(files, dict):
                continue
            for file_key, sha_key in (
                ('csv', 'csv_sha256'),
                ('host_jsonl', 'host_jsonl_sha256'),
                ('summary', 'summary_sha256'),
                ('json', 'json_sha256'),
            ):
                ref = files.get(file_key)
                digest = files.get(sha_key)
                if isinstance(ref, str) and ref and isinstance(digest, str) and SHA256_RE.fullmatch(digest):
                    entries.append((ref, digest, True))

    return entries


def verify_declared_file_digests(
    payload: dict,
    artifact_path: pathlib.Path,
    window_dir: pathlib.Path,
    evidence_root: pathlib.Path,
    repo_root: pathlib.Path | None = None,
    strict_workspace_digests: bool = False,
) -> dict:
    """Recompute SHA-256 over real file bytes for all resolvable declared references."""
    verified_evidence = 0
    verified_workspace = 0
    mismatches: list[str] = []
    missing_required: list[str] = []
    workspace_drift: list[str] = []
    unresolved_count = 0

    for ref, expected, require_local in _collect_declared_file_digests(payload):
        resolved, scope = _resolve_evidence_or_workspace_path(
            ref, artifact_path, window_dir, evidence_root, repo_root
        )
        if resolved is None:
            if require_local:
                missing_required.append(ref)
            elif '/' in ref or FILE_EXT_RE.search(ref):
                unresolved_count += 1
            continue

        actual = sha256_file(resolved)
        if actual == expected:
            if scope == 'evidence':
                verified_evidence += 1
            else:
                verified_workspace += 1
        elif scope == 'evidence' or strict_workspace_digests:
            mismatches.append(ref)
        else:
            workspace_drift.append(ref)

    return {
        'verifiedEvidenceDigestCount': verified_evidence,
        'verifiedWorkspaceDigestCount': verified_workspace,
        'mismatchedReferences': mismatches,
        'missingReferencedFiles': missing_required,
        'workspaceDriftReferences': workspace_drift,
        'unresolvedReferenceCount': unresolved_count,
    }


def classify_real_evidence_kind(payload: dict, rel_path: str) -> str | None:
    """Recognize real-device evidence across Window A, Window B, and Window C schemas."""
    schema = str(payload.get('schema', '')).lower()
    kind = str(payload.get('kind', payload.get('evidenceType', ''))).lower()

    if any(token in schema for token in ('performance-sample', 'phase2-real', 'guest-run', 'wdk-probe', 'wine-bench')):
        return 'standard-phase2-real'
    if any(token in kind for token in ('real-guest', 'real-wdk', 'real-wine', 'real-performance', 'benchmark')):
        return 'standard-phase2-real'
    for key in REAL_EXECUTION_KEYS:
        val = payload.get(key)
        if val is True or (isinstance(val, str) and val.lower() in {'passed', 'verified', 'executed', 'true'}):
            return 'standard-phase2-real'

    # Window A: nested stageA2 real guest verification, real-m0/m1 runs, and verified native artifact fingerprints.
    stage_a2 = payload.get('stageA2RealGuestE2EVerification')
    if isinstance(stage_a2, dict) and str(stage_a2.get('status', '')).lower() == 'passed':
        return 'window-a-real-guest-e2e'
    if isinstance(payload.get('realRunID'), str) and payload.get('realRunID'):
        return 'window-a-real-interactive'
    artifacts = payload.get('artifacts')
    if isinstance(artifacts, list) and any(
        isinstance(item, dict) and item.get('realGuestVerified') is True for item in artifacts
    ):
        return 'window-a-verified-artifacts'

    # Window B: native ARM64 driver build and full-lifecycle load/unload real verification.
    stage_b = str(payload.get('stage', '')).lower()
    if stage_b == 'build-native' and payload.get('exit_code') == 0 and isinstance(payload.get('stdout'), str):
        if '"driver_build": "passed"' in payload['stdout'] and '"architecture": "ARM64"' in payload['stdout']:
            return 'window-b-native-arm64-build'
    if stage_b == 'lifecycle-cycle' and payload.get('exit_code') == 0 and isinstance(payload.get('stdout'), str):
        if '"loadState": "loaded"' in payload['stdout'] and '"loadState": "notLoaded"' in payload['stdout']:
            return 'window-b-native-driver-lifecycle'

    # Window C: Wine three-engine, Guest C3 offload, and M0/M2 records.
    if isinstance(payload.get('runs'), list) and payload['runs']:
        return 'window-c-benchmark-manifest'
    if payload.get('guest_m0_complete') is True and 'm0-m2' in rel_path:
        return 'window-c-m0-m2-status'

    return None


def requires_immutable_digest_binding(payload: dict) -> bool:
    """Determine whether a JSON artifact requires explicit source/binary SHA-256 bindings."""
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


def validate_evidence_file(
    path: pathlib.Path,
    evidence_root: pathlib.Path,
    repo_root: pathlib.Path | None = None,
    strict_workspace_digests: bool = False,
) -> dict:
    """Validate one JSON evidence artifact under handoff/phase-2/evidence/."""
    rel = str(path.relative_to(evidence_root))
    window_dir = evidence_root / pathlib.PurePosixPath(rel).parts[0]
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
            'realEvidenceKind': None,
            'passed': False,
            'errors': ['invalid_json', *errors],
        }

    if not isinstance(payload, dict):
        return {
            'file': rel,
            'fileSHA256': file_sha256,
            'requiresDigestBinding': False,
            'realEvidenceKind': None,
            'passed': False,
            'errors': ['json_object_required', *errors],
        }

    needs_binding = requires_immutable_digest_binding(payload)
    real_kind = classify_real_evidence_kind(payload, rel)
    source_binding, binary_binding = extract_digest_bindings(payload)

    if needs_binding:
        if not is_valid_sha256_binding(source_binding):
            errors.append('missing_or_invalid_sourceSHA256')
        if not is_valid_sha256_binding(binary_binding):
            errors.append('missing_or_invalid_binarySHA256')

    digest_audit = verify_declared_file_digests(
        payload,
        artifact_path=path,
        window_dir=window_dir,
        evidence_root=evidence_root,
        repo_root=repo_root,
        strict_workspace_digests=strict_workspace_digests,
    )
    for ref in digest_audit['mismatchedReferences']:
        errors.append(f'digest_mismatch:{ref}')
    for ref in digest_audit['missingReferencedFiles']:
        errors.append(f'missing_referenced_file:{ref}')

    return {
        'file': rel,
        'fileSHA256': file_sha256,
        'schema': payload.get('schema'),
        'requiresDigestBinding': needs_binding,
        'realEvidenceKind': real_kind,
        'hasValidSourceSHA256': is_valid_sha256_binding(source_binding),
        'hasValidBinarySHA256': is_valid_sha256_binding(binary_binding),
        'digestAudit': digest_audit,
        'passed': not errors,
        'errors': errors,
    }


def _should_skip_json(path: pathlib.Path) -> bool:
    if path.name.endswith('.template.json') or path.name.endswith('.schema.json'):
        return True
    parts = set(path.parts)
    if 'scratch' in parts and 'build' in parts:
        return True
    return False


def validate_phase2_evidence(
    evidence_root: pathlib.Path,
    repo_root: pathlib.Path | None = None,
    strict_workspace_digests: bool = False,
) -> dict:
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
                'verifiedEvidenceDigestCount': 0,
                'verifiedWorkspaceDigestCount': 0,
                'realEvidenceKinds': [],
                'artifacts': [],
                'passed': True,
            }
            continue

        json_files = sorted(
            path for path in folder.rglob('*.json')
            if not _should_skip_json(path)
        )
        artifacts = [
            validate_evidence_file(
                path,
                evidence_root,
                repo_root=repo_root,
                strict_workspace_digests=strict_workspace_digests,
            )
            for path in json_files
        ]
        real_artifacts = [item for item in artifacts if item['realEvidenceKind'] is not None]
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

        verified_evidence_count = sum(
            item.get('digestAudit', {}).get('verifiedEvidenceDigestCount', 0) for item in artifacts
        )
        verified_workspace_count = sum(
            item.get('digestAudit', {}).get('verifiedWorkspaceDigestCount', 0) for item in artifacts
        )
        real_kinds = sorted({item['realEvidenceKind'] for item in real_artifacts if item['realEvidenceKind']})

        windows[window] = {
            'status': status,
            'artifactCount': len(artifacts),
            'realExecutionArtifacts': len(real_artifacts),
            'verifiedEvidenceDigestCount': verified_evidence_count,
            'verifiedWorkspaceDigestCount': verified_workspace_count,
            'realEvidenceKinds': real_kinds,
            'artifacts': artifacts,
            'passed': window_passed,
        }

    return {
        'schema': 'task-07-phase2-evidence-v2',
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
    parser.add_argument('--repo-root', type=pathlib.Path, default=root)
    parser.add_argument('--strict-workspace-digests', action='store_true')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    report = validate_phase2_evidence(
        args.evidence_root.resolve(),
        repo_root=args.repo_root.resolve(),
        strict_workspace_digests=args.strict_workspace_digests,
    )
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized, encoding='utf-8')
    print(serialized, end='')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

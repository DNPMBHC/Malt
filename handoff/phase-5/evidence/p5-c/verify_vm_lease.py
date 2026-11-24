#!/usr/bin/env python3
"""Read-only Phase 5A handoff guard. Owner: @DNPMBHC."""
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path


def check(document, now=None, proofs=None):
    now = now or datetime.now(timezone.utc)
    if document.get("status") != "released":
        return False, "phase5a_lease_not_released"
    released = document.get("released_at") or document.get("released_at_utc") or document.get("releasedAt")
    try:
        stamp = datetime.fromisoformat(released.replace("Z", "+00:00"))
        if stamp.tzinfo is None or stamp < datetime(2026, 11, 23, tzinfo=timezone.utc) or stamp > now:
            return False, "release_timestamp_invalid"
    except (AttributeError, TypeError, ValueError):
        return False, "release_timestamp_invalid"
    if "evidence_refs" in document:
        return check_referenced_release(document, stamp, now, proofs)
    created = document.get("created_at") or document.get("created_at_utc")
    try:
        creation_stamp = datetime.fromisoformat(created.replace("Z", "+00:00"))
        if creation_stamp.tzinfo is None or stamp < creation_stamp:
            return False, "release_before_current_lease"
    except (AttributeError, TypeError, ValueError):
        return False, "current_lease_timestamp_missing"
    if document.get("owner") != "@DNPMBHC":
        return False, "handoff_owner_invalid"
    for field in ("source_stopped", "writable_disks_contained", "shared_directory_disabled"):
        if document.get(field) is not True:
            return False, field + "_proof_missing"
    if document.get("source_fingerprint_unchanged") is not True:
        return False, "primary_unchanged_proof_missing"
    if not any(document.get(key) is True for key in ("clone_deleted", "clone_removed", "clone_cleanup_verified")):
        return False, "clone_cleanup_proof_missing"
    if document.get("next_window") not in ("5C", "window-5c", "C"):
        return False, "handoff_target_invalid"
    return True, "phase5a_handoff_verified"


def source_signature(document):
    files = document.get("files")
    if not isinstance(files, list) or len(files) < 2:
        raise ValueError("source_artifacts_missing")
    values = []
    aliases = set()
    for entry in files:
        alias = entry.get("artifact_alias")
        if not isinstance(alias, str) or not re.fullmatch(r"vm-file-[0-9]+(?:[.][a-z0-9]+)?", alias) or alias in aliases:
            raise ValueError("source_artifact_alias_invalid")
        aliases.add(alias)
        if not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", "")):
            raise ValueError("source_artifact_digest_invalid")
        if type(entry.get("size_bytes")) is not int or type(entry.get("mtime_ns")) is not int or entry["size_bytes"] <= 0 or entry["mtime_ns"] <= 0:
            raise ValueError("source_artifact_metadata_invalid")
        values.append((alias, entry["size_bytes"], entry["mtime_ns"], entry["sha256"]))
    if not any(a.endswith(".qcow2") for a in aliases) or not any(a.endswith(".plist") for a in aliases):
        raise ValueError("source_disk_and_configuration_required")
    if document.get("total_bytes") != sum(v[1] for v in values):
        raise ValueError("source_size_sum_invalid")
    return sorted(values)


def check_referenced_release(document, released, now, proofs):
    required = {"vm-source-before.json", "vm-source-after.json", "vm-cleanup-proof.json"}
    if not isinstance(document.get("evidence_refs"), list) or set(document["evidence_refs"]) != required:
        return False, "current_release_references_missing"
    if document.get("owner") != "@DNPMBHC" or document.get("next_window") != "5C":
        return False, "handoff_identity_invalid"
    fields = ("isolated_clone_deleted", "shared_directory_disabled", "writable_disks_contained", "source_sha256_and_mtime_unchanged")
    if any(document.get(field) is not True for field in fields) or document.get("source_status") != "stopped":
        return False, "current_release_safety_proof_missing"
    try:
        if proofs is None:
            directory = Path(__file__).resolve().parents[1] / "p5-a"
            proofs = {name: json.loads((directory / name).read_text()) for name in required}
        if set(proofs) != required:
            return False, "current_release_references_missing"
        cleanup = proofs["vm-cleanup-proof.json"]
        identity_fields = (*fields, "owner", "next_window", "status", "source_status", "released_at", "verified_at", "pre_delete_runtime_isolation")
        if any(cleanup.get(field) != document.get(field) for field in identity_fields):
            return False, "cleanup_release_identity_mismatch"
        isolation = cleanup["pre_delete_runtime_isolation"]
        if isolation.get("source_registration_state") != "stopped" or isolation.get("source_runtime_absent_verified") is not True or isolation.get("all_hypervisor_workers_bound_to_owned_clone") is not True or isolation.get("worker_count") != 0 or isolation.get("root_pids") != []:
            return False, "release_live_isolation_proof_missing"
        stopped = datetime.fromisoformat(isolation["captured_at_utc"].replace("Z", "+00:00"))
        verified = datetime.fromisoformat(document["verified_at"].replace("Z", "+00:00"))
        if stopped.tzinfo is None or verified.tzinfo is None or not datetime(2026, 11, 23, tzinfo=timezone.utc) <= stopped <= released <= verified <= now:
            return False, "release_proof_timestamps_invalid"
        if source_signature(proofs["vm-source-before.json"]) != source_signature(proofs["vm-source-after.json"]):
            return False, "referenced_source_fingerprint_mismatch"
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return False, "current_release_proofs_invalid"
    return True, "phase5a_referenced_handoff_verified"


def self_test():
    now = datetime(2026, 11, 24, tzinfo=timezone.utc)
    valid = {"status": "released", "released_at": "2026-11-23T15:00:00Z",
             "created_at": "2026-11-23T14:00:00Z", "owner": "@DNPMBHC",
             "source_stopped": True, "writable_disks_contained": True, "shared_directory_disabled": True,
             "source_fingerprint_unchanged": True, "clone_deleted": True, "next_window": "5C"}
    assert check(valid, now)[0]
    changes = ({"status": "held"}, {"released_at": "2026-11-22T15:00:00Z"},
               {"released_at": "2026-12-01T00:00:00Z"}, {"source_fingerprint_unchanged": False},
               {"clone_deleted": False}, {"next_window": "5A"},
               {"created_at": None}, {"created_at": "2026-11-23T16:00:00Z"},
               {"owner": None}, {"source_stopped": False}, {"writable_disks_contained": False},
               {"shared_directory_disabled": False})
    for change in changes:
        assert not check(dict(valid, **change), now)[0]
    from copy import deepcopy
    now = datetime(2026, 11, 24, 6, tzinfo=timezone.utc)
    current = {"owner": "@DNPMBHC", "status": "released", "next_window": "5C",
               "released_at": "2026-11-24T04:01:12Z", "verified_at": "2026-11-24T04:01:13Z",
               "isolated_clone_deleted": True, "shared_directory_disabled": True,
               "writable_disks_contained": True, "source_sha256_and_mtime_unchanged": True,
               "source_status": "stopped", "evidence_refs": ["vm-source-before.json", "vm-source-after.json", "vm-cleanup-proof.json"],
               "pre_delete_runtime_isolation": {"source_registration_state": "stopped",
                 "source_runtime_absent_verified": True, "all_hypervisor_workers_bound_to_owned_clone": True,
                 "root_pids": [], "worker_count": 0, "captured_at_utc": "2026-11-24T04:00:41Z"}}
    baseline = {"total_bytes": 3, "files": [
        {"artifact_alias": "vm-file-0.qcow2", "size_bytes": 2, "mtime_ns": 1, "sha256": "a" * 64},
        {"artifact_alias": "vm-file-1.plist", "size_bytes": 1, "mtime_ns": 2, "sha256": "b" * 64}]}
    proof = {"vm-source-before.json": deepcopy(baseline), "vm-source-after.json": deepcopy(baseline), "vm-cleanup-proof.json": deepcopy(current)}
    assert check(current, now, proof)[0]
    cases = []
    changed = deepcopy(proof); changed.pop("vm-source-after.json"); cases.append(changed)
    changed = deepcopy(proof); changed["vm-source-after.json"]["files"][0]["sha256"] = "c" * 64; cases.append(changed)
    changed = deepcopy(proof); changed["vm-source-after.json"]["files"][0]["mtime_ns"] += 1; cases.append(changed)
    changed = deepcopy(proof); changed["vm-source-after.json"]["files"] = []; cases.append(changed)
    changed = deepcopy(proof); changed["vm-cleanup-proof.json"]["isolated_clone_deleted"] = False; cases.append(changed)
    changed = deepcopy(proof); changed["vm-cleanup-proof.json"]["released_at"] = "2026-11-23T04:01:12Z"; cases.append(changed)
    for changed in cases:
        assert not check(current, now, changed)[0]
    for delta in ({"status": "held"}, {"evidence_refs": ["../outside.json"]}, {"isolated_clone_deleted": False}, {"source_status": "started"}, {"verified_at": "2026-12-01T00:00:00Z"}):
        changed = dict(current, **delta)
        changed_proof = deepcopy(proof); changed_proof["vm-cleanup-proof.json"] = deepcopy(changed)
        assert not check(changed, now, changed_proof)[0]
    for delta in ({"worker_count": 1}, {"root_pids": [123]}, {"source_runtime_absent_verified": False}, {"captured_at_utc": "2026-11-24T05:00:00Z"}):
        changed = deepcopy(current); changed["pre_delete_runtime_isolation"].update(delta)
        changed_proof = deepcopy(proof); changed_proof["vm-cleanup-proof.json"] = deepcopy(changed)
        assert not check(changed, now, changed_proof)[0]
    return 29


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lease", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps({"owner": "@DNPMBHC", "self_tests_passed": self_test()}))
        return 0
    path = args.lease or Path(__file__).resolve().parents[1] / "p5-a" / "vm-lease.json"
    try:
        allowed, reason = check(json.loads(path.read_text()))
    except (OSError, ValueError):
        allowed, reason = False, "phase5a_lease_unavailable"
    print(json.dumps({"owner": "@DNPMBHC", "vm_allowed": allowed, "reason": reason}))
    return 0 if allowed else 2


if __name__ == "__main__":
    raise SystemExit(main())

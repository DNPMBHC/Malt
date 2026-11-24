#!/usr/bin/env python3
"""Close only the owned disposable environment. Owner: @DNPMBHC."""
import argparse
import importlib.util
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, EVIDENCE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


runtime = module("closeout_runtime", "run_guest_runtime_validation.py")
clone = runtime.clone
bootstrap = module("closeout_bootstrap", "bootstrap_guest_clone.py")
installer = module("closeout_installer", "run_official_installer.py")
client = module("closeout_client", "prepare_client_backup.py")


def stamp():
    return datetime.now(timezone.utc).isoformat()


def record(name, **values):
    data = dict(owner="@DNPMBHC", captured_at_utc=stamp(), **values)
    clone.save(EVIDENCE / name, data)
    return data


def progress(stage):
    print(json.dumps({"owner": "@DNPMBHC", "stage": stage}), flush=True)


def safe_error(error):
    return str(error) if isinstance(error, RuntimeError) else type(error).__name__


def handles_absent(paths, reject_all=False):
    result = subprocess.run(["lsof", "-Fpcfa", "--", *map(str, paths)], capture_output=True, timeout=30)
    if result.returncode not in (0, 1) or result.stderr:
        raise RuntimeError("open_handle_audit_unavailable")
    lines = result.stdout.splitlines()
    if reject_all and lines:
        raise RuntimeError("owned_artifact_handle_remaining")
    if any(line in (b"aw", b"au") or line.startswith(b"c") and b"qemu" in line.lower() for line in lines):
        raise RuntimeError("protected_writable_or_qemu_handle_detected")
    return True


def terminal(observed):
    return observed.get("state") == "exited" and observed.get("rootExited") is True and observed.get("activeProcessCount") == 0


def cancel_installer():
    owned, identifier = runtime.authorize()
    state = clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower()
    result = dict(clone_state=state, attempted=False, authenticated_terminal_receipt=False,
                  shutdown_fallback_required=True, natural_game_exit_code_recorded=False)
    try:
        previous = json.loads(installer.RECORD.read_text())
        if previous.get("owner") != "@DNPMBHC" or previous.get("clone_identifier") != identifier:
            raise RuntimeError("installer_record_owner_mismatch")
        if state != "started":
            raise RuntimeError("owned_guest_not_running_for_process_receipt")
        token = previous["request_id"]
        observed = installer.status(identifier, token)
        expected = previous["observed"]
        identity = ("controllerPID", "targetPID", "targetCreationTime", "sessionID")
        if any(observed.get(key) != expected.get(key) for key in identity):
            raise RuntimeError("installer_process_identity_mismatch")
        result.update(attempted=True, before=observed)
        for operation in ("cancel", "force-cancel"):
            if terminal(observed):
                break
            checked, checked_id = clone.own_clone(json.loads(clone.LEASE.read_text()))
            if checked != owned or checked_id != identifier:
                raise RuntimeError("cancel_owned_clone_identity_mismatch")
            try:
                response = bootstrap.powershell(identifier, "& '" + installer.HELPER + "' '" + operation + "' '" + token + "'|ConvertFrom-Json", timeout=30)
                if response.get("requestID") != token:
                    raise RuntimeError("cancel_response_identity_mismatch")
                result[operation + "_response"] = {key: response.get(key) for key in ("requestID", "state", "cancelled", "rootExited", "rootExitCode", "activeProcessCount", "error", "win32Error")}
            except Exception as error:
                result[operation + "_error"] = safe_error(error)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                observed = installer.status(identifier, token)
                if any(observed.get(key) != expected.get(key) for key in identity):
                    raise RuntimeError("installer_process_identity_changed")
                if terminal(observed):
                    break
                time.sleep(0.5)
        result.update(after=observed, authenticated_terminal_receipt=terminal(observed),
                      shutdown_fallback_required=not terminal(observed),
                      exit_observation_kind="operator_cleanup" if observed.get("cancelled") else "installer_observation")
    except Exception as error:
        result["error_code"] = safe_error(error)
    record("official-installer-closeout.json", **result)
    progress("installer_closeout_recorded")


def stop_owned(owned, identifier):
    ctl = str(clone.controller())
    state = clone.command([ctl, "status", identifier]).decode().strip().lower()
    method = "already_stopped"
    if state not in ("started", "paused", "stopped"):
        raise RuntimeError("owned_shutdown_state_invalid")
    if state == "started":
        method = "guest_request"
        try:
            requested = subprocess.run([ctl, "stop", "--hide", identifier, "--request"], capture_output=True, timeout=20)
            if requested.returncode:
                method = "owned_poweroff_after_request_failure"
        except subprocess.TimeoutExpired:
            method = "owned_poweroff_after_request_timeout"
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if clone.command([ctl, "status", identifier]).decode().strip().lower() == "stopped":
                break
            time.sleep(0.5)
    if clone.command([ctl, "status", identifier]).decode().strip().lower() != "stopped":
        checked, checked_id = clone.own_clone(json.loads(clone.LEASE.read_text()))
        if checked != owned or checked_id != identifier:
            raise RuntimeError("owned_poweroff_identity_mismatch")
        method = "owned_poweroff_after_guest_request" if state == "started" else "owned_paused_poweroff"
        clone.command([ctl, "stop", "--hide", identifier, "--force"], timeout=30)
    if clone.command([ctl, "status", identifier]).decode().strip().lower() != "stopped":
        raise RuntimeError("owned_shutdown_not_confirmed")
    record("own-closeout-shutdown.json", method=method, only_owned_clone_controlled=True,
           primary_vm_control_actions=0, stopped=True)


def cleanup():
    owned, identifier = runtime.authorize()
    before = json.loads((EVIDENCE / "own-source-before.json").read_text())
    original_before = json.loads((EVIDENCE / "own-client-source-before.json").read_text())
    original = client.donor(original_before)
    handles_absent([original])
    owned_files = [p for p in owned.rglob("*") if p.is_file()]
    stop_owned(owned, identifier)
    handles_absent(owned_files, reject_all=True)
    progress("owned_clone_stopped_deleting")
    clone.cleanup()
    progress("owned_clone_deleted_verifying_original_backup")
    source, _ = clone.source_bundle()
    clone.assert_no_source_control_process(source)
    after = json.loads((EVIDENCE / "own-source-after-cleanup.json").read_text())
    original_after = {"size_bytes": original.stat().st_size, "mtime_ns": original.stat().st_mtime_ns,
                      "sha256": clone.digest(original)}
    if any(original_after[key] != original_before[key] for key in original_after):
        raise RuntimeError("original_client_after_cleanup_mismatch")
    handles_absent([original])
    record("own-client-source-after-cleanup.json", **original_after)
    listing = clone.command([str(clone.controller()), "list"]).decode().lower()
    processes = clone.command(["ps", "-axo", "args="]).decode("utf-8", "replace")
    if owned.exists() or identifier.lower() in listing:
        raise RuntimeError("owned_clone_cleanup_incomplete")
    if any((str(owned) in line or identifier.lower() in line.lower()) and any(word in line.lower() for word in ("qemu", "utmctl", "osascript")) for line in processes.splitlines()):
        raise RuntimeError("owned_worker_remaining")
    handles_absent(owned_files, reject_all=True)
    # Source file contents and metadata are independently read, never inferred from another window's report.
    unchanged = clone.signature(before) == clone.signature(after)
    if not unchanged:
        raise RuntimeError("primary_source_after_cleanup_mismatch")
    cancellation = json.loads((EVIDENCE / "official-installer-closeout.json").read_text())
    rollback_path = EVIDENCE / "guest-minimal-rollback.json"
    rollback = json.loads(rollback_path.read_text()) if rollback_path.exists() else {}
    result = record("own-cleanup-proof.json", passed=True, clone_deleted=True, clone_unregistered=True,
        owned_workers_absent=True, owned_open_handles_absent=True, original_client_unchanged=True,
        original_client_writable_and_qemu_handles_absent=True, source_fingerprint_unchanged=unchanged,
        source_file_count=len(after["files"]), source_stopped=True, source_writable_and_qemu_handles_absent=True,
        owned_client_copy_and_installer_media_deleted=True, vm_lease_status="released",
        primary_vm_control_actions=0, installer_terminal_receipt=cancellation.get("authenticated_terminal_receipt") is True,
        minimal_rollback_verified=rollback.get("rollback_consistent") is True,
        resolution_restore_from_latest_failed_run_verified=False,
        cleanup_scope="only_owned_external_apfs_clone", real_validation="user_deferred_to_next_phase",
        evidence_refs=["own-source-before.json", "own-source-after-cleanup.json", "own-client-source-before.json",
                       "own-client-source-after-cleanup.json", "official-installer-closeout.json", "own-closeout-shutdown.json"])
    print(json.dumps({key: result[key] for key in ("passed", "clone_deleted", "source_fingerprint_unchanged", "original_client_unchanged")}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("cancel-installer", "cleanup"))
    args = parser.parse_args()
    try:
        if args.action == "cancel-installer":
            cancel_installer()
        else:
            cleanup()
        return 0
    except Exception as error:
        record("own-closeout-failure.json", stage=args.action, error_code=safe_error(error), passed=False)
        print(json.dumps({"owner": "@DNPMBHC", "error_code": safe_error(error), "passed": False}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

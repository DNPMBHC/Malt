#!/usr/bin/env python3
"""Read-only donor audit and APFS game-disk copy inside the owned clone. Owner: @DNPMBHC."""
import argparse
import ctypes
import plistlib
import uuid
import importlib.util
import json
import os
import subprocess
import time
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("client_clone", EVIDENCE / "guest_clone_control.py")
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)


def donor(expected):
    queue = [(p, 0) for p in Path("/Volumes").iterdir() if p.is_dir() and not p.is_symlink()]
    matches = []
    while queue:
        directory, depth = queue.pop()
        try:
            for path in directory.iterdir():
                if path.is_file() and not path.is_symlink() and path.suffix == ".qcow2":
                    stat = path.stat()
                    if stat.st_size == expected["size_bytes"] and stat.st_mtime_ns == expected["mtime_ns"]:
                        matches.append(path)
                elif path.is_dir() and not path.is_symlink() and depth < 4 and path.suffix != ".utm":
                    queue.append((path, depth + 1))
        except OSError:
            continue
    if len(matches) != 1: raise RuntimeError("client_donor_not_unique")
    return matches[0]


def attach_offline(owned, identifier):
    processes = clone.command(["ps", "-axo", "comm=,args="]).decode("utf-8", "replace")
    state = clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower()
    if state != "stopped" or any("qemu" in line.lower() and str(owned) in line for line in processes.splitlines()):
        raise RuntimeError("offline_configuration_requires_owned_clone_stopped")
    report = json.loads((EVIDENCE / "own-client-copy-readiness.json").read_text())
    if report.get("clone_identifier") != identifier or report.get("attached") is not False:
        raise RuntimeError("client_copy_ownership_or_state_invalid")
    target = owned / "Data/client-backup.qcow2"
    if clone.digest(target) != report["sha256"]:
        raise RuntimeError("client_copy_changed_before_attach")
    config = plistlib.loads((owned / "config.plist").read_bytes())
    if any(d.get("ImageName") == target.name for d in config["Drive"]):
        raise RuntimeError("client_disk_already_configured")
    config["Drive"].append({"Identifier": str(uuid.uuid4()).upper(), "ImageType": "Disk",
                            "Interface": "NVMe", "InterfaceVersion": 1,
                            "ImageName": target.name, "ReadOnly": False})
    clone.validate_disks(owned, config)
    (owned / "config.plist").write_bytes(plistlib.dumps(config))
    reload_script = """on run argv
      tell application id "com.utmapp.UTM"
        reload configuration (virtual machine id (item 1 of argv))
      end tell
    end run"""
    clone.command(["osascript", "-e", reload_script, "--", identifier], timeout=30)
    reloaded = plistlib.loads((owned / "config.plist").read_bytes())
    if sum(d.get("ImageName") == target.name for d in reloaded["Drive"]) != 1:
        raise RuntimeError("owned_client_configuration_readback_failed")
    clone.validate_disks(owned, reloaded)
    report.update(attached=True, attachment_status="offline_configured_and_reloaded_pending_guest_enumeration",
                  only_owned_clone_reloaded=True, application_quit_actions=0)
    clone.save(EVIDENCE / "own-client-copy-readiness.json", report)
    return {"owner": "@DNPMBHC", "client_copy_configured": True, "guest_enumeration_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("copy", "attach"), default="copy", nargs="?")
    args = parser.parse_args()
    try:
        previous = json.loads((clone.A_EVIDENCE / "vm-lease.json").read_text())
        allowed, reason = clone.guard.check(previous)
        if not allowed: raise RuntimeError(reason)
        lease = json.loads(clone.LEASE.read_text())
        if lease.get("status") != "held": raise RuntimeError("owned_clone_not_held")
        owned, identifier = clone.own_clone(lease)
        if args.action == "attach":
            runtime_spec = importlib.util.spec_from_file_location("attach_runtime_guard", EVIDENCE / "run_guest_runtime_validation.py")
            runtime = importlib.util.module_from_spec(runtime_spec)
            runtime_spec.loader.exec_module(runtime)
            verified_owned, verified_id = runtime.authorize()
            if verified_owned != owned or verified_id != identifier:
                raise RuntimeError("attach_guard_identity_mismatch")
            state = clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower()
            if state == "paused":
                clone.command([str(clone.controller()), "start", "--hide", identifier])
                state = "started"
            if state == "started":
                clone.command([str(clone.controller()), "stop", "--hide", identifier, "--request"])
                deadline = time.monotonic() + 90
                while clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower() != "stopped":
                    if time.monotonic() >= deadline:
                        verified_owned, verified_id = clone.own_clone(json.loads(clone.LEASE.read_text()))
                        if verified_owned != owned or verified_id != identifier:
                            raise RuntimeError("owned_poweroff_identity_mismatch")
                        clone.save(EVIDENCE / "client-attach-shutdown.json", {
                            "owner": "@DNPMBHC", "guest_shutdown_timed_out": True,
                            "force_poweroff_only_owned_clone": True, "primary_vm_control_actions": 0})
                        clone.command([str(clone.controller()), "stop", "--hide", identifier, "--force"])
                        break
                    time.sleep(1)
            elif state != "stopped":
                raise RuntimeError("owned_attach_state_invalid")
            print(json.dumps(attach_offline(owned, identifier)), flush=True)
            return 0
        reference = json.loads((clone.A_EVIDENCE / "client-backup-final-proof.json").read_text())
        if reference.get("owner") != "@DNPMBHC" or reference.get("original_preserved") is not True:
            raise RuntimeError("client_donor_reference_invalid")
        original = donor(reference)
        clone.external_apfs(original.parent)
        handles = subprocess.run(["lsof", "-Fpcfa", "--", str(original)], capture_output=True, timeout=30)
        if handles.returncode not in (0, 1) or handles.stderr or any(line in (b"aw", b"au") or line.startswith(b"c") and b"qemu" in line.lower() for line in handles.stdout.splitlines()):
            raise RuntimeError("client_donor_writable_handle_rejected")
        print(json.dumps({"owner": "@DNPMBHC", "stage": "independent_original_client_sha256"}), flush=True)
        before = {"size_bytes": original.stat().st_size, "mtime_ns": original.stat().st_mtime_ns,
                  "sha256": clone.digest(original)}
        if any(before[k] != reference[k] for k in before): raise RuntimeError("client_donor_source_mismatch")
        clone.save(EVIDENCE / "own-client-source-before.json", dict(before, owner="@DNPMBHC"))
        target = owned / "Data/client-backup.qcow2"
        if target.exists(): raise RuntimeError("owned_client_copy_already_exists")
        native = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        native.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        native.clonefile.restype = ctypes.c_int
        if native.clonefile(os.fsencode(original), os.fsencode(target), 0): raise RuntimeError("client_apfs_copy_failed")
        clone.validate_disks(owned, {"Drive": [{"ImageName": target.name, "ReadOnly": False}]})
        print(json.dumps({"owner": "@DNPMBHC", "stage": "independent_client_copy_sha256"}), flush=True)
        if clone.digest(target) != before["sha256"]: raise RuntimeError("client_copy_digest_mismatch")
        if original.stat().st_size != before["size_bytes"] or original.stat().st_mtime_ns != before["mtime_ns"]:
            raise RuntimeError("client_donor_metadata_changed")
        report = dict(before, owner="@DNPMBHC", attached=False, clone_identifier=identifier,
                      clone_image_alias=target.name, apfs_clonefile_verified=True, copy_digest_verified=True,
                      disk_inside_owned_bundle=True, backing_chain_absent=True,
                      writable_original_never_attached=True)
        clone.save(EVIDENCE / "own-client-copy-readiness.json", report)
        print(json.dumps({"owner": "@DNPMBHC", "client_copy_ready": True, "attached": False}), flush=True)
        return 0
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        print(json.dumps({"owner": "@DNPMBHC", "error_code": str(error) if isinstance(error, RuntimeError) else type(error).__name__}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Guarded external APFS clone lifecycle. Owner: @DNPMBHC."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
A_EVIDENCE = EVIDENCE.parent / "p5-a"
LEASE = EVIDENCE / "vm-lease.json"
spec = importlib.util.spec_from_file_location("lease_guard", EVIDENCE / "verify_vm_lease.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def save(path, value):
    temporary = path.with_suffix(".pending")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def command(arguments, timeout=30):
    result = subprocess.run(arguments, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("control_command_failed")
    return result.stdout


def controller():
    return next(p / "Contents/MacOS/utmctl" for p in Path("/Applications").glob("UTM*.app")
                if (p / "Contents/MacOS/utmctl").is_file())


def bundles():
    queue = [(p, 0) for p in Path("/Volumes").iterdir() if p.is_dir() and not p.is_symlink()]
    checked = 0
    while queue:
        directory, depth = queue.pop()
        checked += 1
        if checked > 6000:
            raise RuntimeError("external_inventory_limit")
        if directory.suffix == ".utm":
            yield directory
            continue
        if depth < 4:
            try:
                queue.extend((p, depth + 1) for p in directory.iterdir()
                             if p.is_dir() and not p.is_symlink() and not p.name.startswith("."))
            except OSError:
                continue


def source_bundle():
    baseline = json.loads((A_EVIDENCE / "vm-source-before.json").read_text())
    hashes = {entry["sha256"] for entry in baseline["files"] if entry["artifact_alias"].endswith(".plist")}
    matches = [p for p in bundles() if (p / "config.plist").is_file()
               and digest(p / "config.plist") in hashes]
    if len(matches) != 1:
        raise RuntimeError("primary_source_not_unique")
    return matches[0], baseline


def external_apfs(bundle):
    canonical = bundle.resolve(strict=True)
    if canonical != bundle or len(bundle.parts) < 4 or bundle.parts[1] != "Volumes":
        raise RuntimeError("external_bundle_path_invalid")
    volume = Path(*bundle.parts[:3])
    info = plistlib.loads(command(["diskutil", "info", "-plist", str(volume)]))
    if info.get("FilesystemType") != "apfs" or info.get("Internal") is not False or info.get("Writable") is not True:
        raise RuntimeError("external_writable_apfs_required")
    info["available_bytes"] = shutil.disk_usage(volume).free
    return info


def fingerprint(bundle):
    result = []
    for index, path in enumerate(sorted(p for p in bundle.rglob("*") if p.is_file())):
        if path.is_symlink() or not path.resolve().is_relative_to(bundle):
            raise RuntimeError("bundle_symlink_rejected")
        stat = path.stat()
        result.append({"artifact_alias": "vm-file-" + str(index) + path.suffix,
                       "size_bytes": stat.st_size, "mtime_ns": stat.st_mtime_ns, "sha256": digest(path)})
    return {"files": result, "total_bytes": sum(p["size_bytes"] for p in result)}


def signature(document):
    return sorted((p["size_bytes"], p["mtime_ns"], p["sha256"]) for p in document["files"])


def assert_no_source_control_process(bundle):
    config = plistlib.loads((bundle / "config.plist").read_bytes())
    source_id = str(config["Information"]["UUID"])
    listing = command([str(controller()), "list"]).decode("utf-8", "replace")
    for line in listing.splitlines():
        if source_id.lower() in line.lower() and "stopped" not in line.lower():
            raise RuntimeError("primary_source_not_stopped")
    processes = command(["ps", "-axo", "args="]).decode("utf-8", "replace")
    if any("qemu" in line.lower() and str(bundle) in line for line in processes.splitlines()):
        raise RuntimeError("primary_source_process_detected")
    files = [str(path) for path in bundle.rglob("*") if path.is_file()]
    opened = subprocess.run(["lsof", "-Fpcfa", "--"] + files, capture_output=True, timeout=30)
    if opened.returncode not in (0, 1) or opened.stderr:
        raise RuntimeError("primary_open_file_audit_unavailable")
    for line in opened.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("c") and "qemu" in line.lower() or line in ("aw", "au"):
            raise RuntimeError("primary_writable_or_qemu_handle_detected")
    return source_id


def validate_disks(bundle, config):
    disks = []
    for drive in config["Drive"]:
        name = drive.get("ImageName")
        if not name:
            if drive.get("ReadOnly") is not True:
                raise RuntimeError("writable_drive_without_image")
            continue
        if Path(name).name != name or ".." in name:
            raise RuntimeError("drive_path_escape_rejected")
        path = bundle / "Data" / name
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(bundle):
            raise RuntimeError("disk_not_contained")
        if path.suffix == ".qcow2":
            with path.open("rb") as stream:
                header = stream.read(104)
            version = struct.unpack(">I", header[4:8])[0] if len(header) >= 8 else 0
            if len(header) < 72 or header[:4] != b"QFI\xfb" or version not in (2, 3) or struct.unpack(">QI", header[8:20]) != (0, 0):
                raise RuntimeError("qcow_backing_chain_rejected")
            if version == 3 and (len(header) < 104 or struct.unpack(">Q", header[72:80])[0] & 7):
                raise RuntimeError("qcow_dirty_corrupt_or_external_data_rejected")
        disks.append(path)
    if not disks:
        raise RuntimeError("guest_disk_missing")
    return disks


def clone_files(source, destination, lease):
    native = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    native.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    native.clonefile.restype = ctypes.c_int
    destination.mkdir()
    save(destination / "clone-owner.json", {"owner": "@DNPMBHC", "clone_identifier": lease["clone_identifier"],
                                           "created_at": lease["created_at"]})
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("bundle_symlink_rejected")
        target = destination / path.relative_to(source)
        if path.is_dir():
            target.mkdir()
        elif path.is_file():
            if native.clonefile(os.fsencode(path), os.fsencode(target), 0) != 0:
                raise RuntimeError("apfs_clonefile_failed")
        else:
            raise RuntimeError("unsupported_bundle_artifact")


def prepare():
    allowed, reason = guard.check(json.loads((A_EVIDENCE / "vm-lease.json").read_text()))
    if not allowed:
        raise RuntimeError(reason)
    if LEASE.exists() and json.loads(LEASE.read_text()).get("status") != "released":
        raise RuntimeError("existing_C_lease_requires_cleanup")
    source, baseline = source_bundle()
    info = external_apfs(source)
    if info["available_bytes"] < 8 * 1024 ** 3:
        raise RuntimeError("external_free_space_insufficient")
    source_id = assert_no_source_control_process(source)
    config = plistlib.loads((source / "config.plist").read_bytes())
    validate_disks(source, config)
    print(json.dumps({"owner": "@DNPMBHC", "stage": "independent_source_fingerprint"}), flush=True)
    before = fingerprint(source)
    if signature(before) != signature(baseline):
        raise RuntimeError("primary_source_baseline_mismatch")
    save(EVIDENCE / "own-source-before.json", dict(before, owner="@DNPMBHC"))
    identifier = str(uuid.uuid4()).upper()
    if identifier.lower() == source_id.lower():
        raise RuntimeError("primary_clone_identity_rejected")
    alias = "test-vm-p5c-" + uuid.uuid4().hex[:12] + ".utm"
    clone = source.parent / alias
    lease = {"owner": "@DNPMBHC", "status": "preparing", "created_at": datetime.now(timezone.utc).isoformat(),
             "clone_alias": alias, "clone_identifier": identifier,
             "primary_identifier_sha256": hashlib.sha256(source_id.upper().encode()).hexdigest(),
             "source_fingerprint_ref": "own-source-before.json", "clone_registered": False,
             "clone_deleted": False, "source_fingerprint_unchanged": True}
    save(LEASE, lease)
    clone_files(source, clone, lease)
    config["Information"].update(Name="test-vm-p5c", UUID=identifier)
    config["Sharing"] = {"ClipboardSharing": False, "DirectoryShareMode": "None", "DirectoryShareReadOnly": True}
    for display in config["Display"]:
        display["Hardware"] = "virtio-ramfb-gl"
    (clone / "config.plist").write_bytes(plistlib.dumps(config))
    validate_disks(clone, config)
    if config["System"]["Architecture"] != "aarch64" or not all(
            config["QEMU"].get(k) is True for k in ("TPMDevice", "UEFIBoot", "Hypervisor")):
        raise RuntimeError("clone_security_configuration_invalid")
    # Open the existing external package in the background; scripting import can wait for a copy workflow.
    command(["open", "-gj", "-a", str(controller().parents[2]), str(clone)])
    deadline = time.monotonic() + 30
    while identifier.lower() not in command([str(controller()), "list"]).decode().lower():
        if time.monotonic() > deadline:
            raise RuntimeError("clone_registration_not_confirmed")
        time.sleep(0.5)
    if command([str(controller()), "status", identifier]).decode().strip().lower() != "stopped":
        raise RuntimeError("new_clone_not_stopped")
    lease.update(status="held", clone_registered=True, writable_disks_contained=True,
                 shared_directory_disabled=True, clone_state="stopped")
    save(LEASE, lease)
    after = fingerprint(source)
    save(EVIDENCE / "own-source-after-prepare.json", dict(after, owner="@DNPMBHC"))
    if signature(before) != signature(after):
        raise RuntimeError("primary_source_changed_during_prepare")
    return {"owner": "@DNPMBHC", "prepared": True, "clone_state": "stopped", "primary_vm_control_actions": 0}


def own_clone(lease):
    if lease.get("owner") != "@DNPMBHC" or not re.fullmatch(r"test-vm-p5c-[0-9a-f]{12}\.utm", lease.get("clone_alias", "")):
        raise RuntimeError("own_clone_lease_invalid")
    identifier = str(uuid.UUID(lease["clone_identifier"])).upper()
    matches = [p for p in bundles() if p.name == lease["clone_alias"]]
    if len(matches) != 1:
        raise RuntimeError("own_clone_not_unique")
    clone = matches[0]
    external_apfs(clone)
    marker = json.loads((clone / "clone-owner.json").read_text())
    if marker.get("owner") != "@DNPMBHC" or marker.get("clone_identifier", "").lower() != identifier.lower() or marker.get("created_at") != lease.get("created_at"):
        raise RuntimeError("own_clone_marker_mismatch")
    config_path = clone / "config.plist"
    config = plistlib.loads(config_path.read_bytes()) if config_path.exists() else None
    if config is None or str(config["Information"]["UUID"]).lower() != identifier.lower():
        if lease.get("status") != "preparing" or lease.get("clone_registered"):
            raise RuntimeError("own_clone_identity_mismatch")
        # A failed, unimported copy may still carry the original config. Its creation marker owns only this new directory.
    if hashlib.sha256(identifier.upper().encode()).hexdigest() == lease["primary_identifier_sha256"]:
        raise RuntimeError("primary_cleanup_rejected")
    return clone, identifier


def cleanup():
    lease = json.loads(LEASE.read_text())
    clone, identifier = own_clone(lease)
    ctl = str(controller())
    registered = identifier.lower() in command([ctl, "list"]).decode().lower()
    if registered:
        config = plistlib.loads((clone / "config.plist").read_bytes())
        if str(config["Information"]["UUID"]).lower() != identifier.lower():
            raise RuntimeError("registered_clone_identity_mismatch")
        status = command([ctl, "status", identifier]).decode().strip().lower()
        if status != "stopped":
            lease["cleanup_shutdown_method"] = "poweroff_paused_clone" if status == "paused" else "guest_request"
            save(LEASE, lease)
            if status == "paused":
                command([ctl, "stop", "--hide", identifier, "--force"], timeout=30)
            else:
                requested = subprocess.run([ctl, "stop", "--hide", identifier, "--request"],
                                           capture_output=True, timeout=30)
                if requested.returncode:
                    raise RuntimeError("clone_graceful_shutdown_request_failed")
            deadline = time.monotonic() + 30
            while command([ctl, "status", identifier]).decode().strip().lower() != "stopped":
                if time.monotonic() > deadline:
                    lease["cleanup_shutdown_method"] = "guest_request_then_owned_clone_poweroff"
                    save(LEASE, lease)
                    command([ctl, "stop", "--hide", identifier, "--force"], timeout=30)
                    break
                time.sleep(0.5)
            if command([ctl, "status", identifier]).decode().strip().lower() != "stopped":
                raise RuntimeError("clone_stop_not_confirmed")
        command([ctl, "delete", "--hide", identifier], timeout=60)
    if clone.exists():
        processes = command(["ps", "-axo", "args="]).decode("utf-8", "replace")
        if any("qemu" in line.lower() and str(clone) in line for line in processes.splitlines()):
            raise RuntimeError("clone_process_cleanup_pending")
        shutil.rmtree(clone)
    if clone.exists() or identifier.lower() in command([ctl, "list"]).decode().lower():
        raise RuntimeError("clone_cleanup_not_confirmed")
    source, _ = source_bundle()
    after = fingerprint(source)
    before = json.loads((EVIDENCE / "own-source-before.json").read_text())
    save(EVIDENCE / "own-source-after-cleanup.json", dict(after, owner="@DNPMBHC"))
    unchanged = signature(before) == signature(after)
    lease.update(status="released" if unchanged else "cleanup_source_mismatch", clone_deleted=True,
                 source_fingerprint_unchanged=unchanged, released_at=datetime.now(timezone.utc).isoformat())
    save(LEASE, lease)
    if not unchanged:
        raise RuntimeError("primary_source_after_cleanup_mismatch")
    return {"owner": "@DNPMBHC", "clone_deleted": True, "primary_source_unchanged": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "prepare", "cleanup"), default="inspect", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            result = prepare()
        elif args.action == "cleanup":
            result = cleanup()
        else:
            source, _ = source_bundle()
            info = external_apfs(source)
            allowed, reason = guard.check(json.loads((A_EVIDENCE / "vm-lease.json").read_text()))
            result = {"owner": "@DNPMBHC", "source_config_matches_A_baseline": True,
                      "external_apfs": True, "external_free_gib": round(info["available_bytes"] / 1024 ** 3, 2),
                      "vm_preparation_allowed": allowed, "reason": reason, "vm_control_actions": 0}
        print(json.dumps(result), flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        # Diagnostics contain a closed error vocabulary, never paths or command output.
        code = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(json.dumps({"owner": "@DNPMBHC", "failed": True, "error_code": code}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

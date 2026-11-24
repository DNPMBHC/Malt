#!/usr/bin/env python3
"""Golden Guest v1 lifecycle manager (verify, APFS CoW spawn, destroy, lease check).

Owner: @DNPMBHC
Safety guarantees:
1. Never modifies or deletes primary cold-backup vm-a.
2. Enforces read-only sealing on golden-win11-arm64-v1.utm after build.
3. Ephemeral clones are created via APFS copy-on-write (cp -cR) with unique UUID/MAC.
4. Destroys only explicitly tagged ephemeral clones and verifies zero drift on golden & vm-a.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import time
from typing import Any
import uuid

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
DEFAULT_PROFILE_PATH = (
    WORKSPACE_ROOT
    / "Whisky"
    / "Modules"
    / "guest-golden"
    / "profiles"
    / "golden-win11-arm64-v1.json"
)
DEFAULT_LEASE_PATH = (
    WORKSPACE_ROOT / "handoff" / "phase-5" / "evidence" / "p5-c" / "vm-lease.json"
)
DEFAULT_UTMCTL = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
EPHEMERAL_META_FILENAME = ".ephemeral-meta.json"
CHUNK_SIZE = 4 * 1024 * 1024


class GoldenGuestError(RuntimeError):
    """Domain error for Golden Guest management."""


class SafetyError(GoldenGuestError):
    """Raised when an operation threatens primary vm-a or sealed golden image."""


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def redact_text(text: str) -> str:
    redacted = str(text)
    redacted = redacted.replace(str(WORKSPACE_ROOT), "<workspace>")
    redacted = redacted.replace(str(Path.home()), "<home>")
    if WORKSPACE_ROOT.name:
        redacted = redacted.replace(WORKSPACE_ROOT.name, "my-project")
    user_name = os.environ.get("USER") or Path.home().name
    if user_name:
        redacted = re.sub(
            r"(?<![\w@])" + re.escape(user_name) + r"(?!\w)",
            "user-x",
            redacted,
            flags=re.IGNORECASE,
        )
    redacted = re.sub(
        r"/Volumes/[^/\s\"'<>`]+",
        "/Volumes/<EXTERNAL_VOLUME>",
        redacted,
    )
    redacted = re.sub(
        r"(?<![\w.])/(?:Users|private/var/folders)/[^\s\"'<>`]+",
        "<local-path>",
        redacted,
    )
    return redacted


def redact_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): redact_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_value(v) for v in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


def write_redacted_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cleaned = redact_value(payload)
    path.write_text(json.dumps(cleaned, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def load_profile(profile_path: Path = DEFAULT_PROFILE_PATH) -> dict[str, Any]:
    if not profile_path.is_file():
        raise GoldenGuestError(f"Profile not found: {redact_text(str(profile_path))}")
    data = json.loads(profile_path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise GoldenGuestError("Golden profile schema_version must be 1")
    return data


def read_config_plist(bundle_path: Path) -> dict[str, Any]:
    cfg_path = bundle_path / "config.plist"
    if not cfg_path.is_file():
        raise GoldenGuestError(f"Missing config.plist in {redact_text(str(bundle_path))}")
    with cfg_path.open("rb") as handle:
        return plistlib.load(handle)


def write_config_plist(bundle_path: Path, config: dict[str, Any]) -> None:
    cfg_path = bundle_path / "config.plist"
    with cfg_path.open("wb") as handle:
        plistlib.dump(config, handle)


def bundle_uuid(bundle_path: Path) -> str:
    config = read_config_plist(bundle_path)
    return str(config.get("Information", {}).get("UUID", "")).strip()


def generate_unicast_mac() -> str:
    raw = bytearray(secrets.token_bytes(6))
    raw[0] = (raw[0] & 0xFC) | 0x02
    return ":".join(f"{b:02X}" for b in raw)


def is_bundle_readonly(bundle_path: Path) -> bool:
    if not bundle_path.is_dir():
        return False
    cfg_path = bundle_path / "config.plist"
    if not cfg_path.is_file():
        return False
    for path in [bundle_path, cfg_path]:
        mode = path.stat().st_mode
        if mode & 0o222:
            return False
    for root, dirs, files in os.walk(bundle_path):
        for name in dirs + files:
            p = Path(root) / name
            if p.stat().st_mode & 0o222:
                return False
    return True


def set_bundle_readonly(bundle_path: Path, readonly: bool) -> None:
    if not bundle_path.is_dir():
        raise GoldenGuestError(f"Bundle directory does not exist: {redact_text(str(bundle_path))}")
    if readonly:
        for root, dirs, files in os.walk(bundle_path, topdown=False):
            for name in files:
                p = Path(root) / name
                p.chmod(p.stat().st_mode & ~0o222)
            for name in dirs:
                p = Path(root) / name
                p.chmod(p.stat().st_mode & ~0o222)
        bundle_path.chmod(bundle_path.stat().st_mode & ~0o222)
    else:
        bundle_path.chmod(bundle_path.stat().st_mode | 0o700)
        for root, dirs, files in os.walk(bundle_path, topdown=True):
            for name in dirs:
                p = Path(root) / name
                p.chmod(p.stat().st_mode | 0o700)
            for name in files:
                p = Path(root) / name
                p.chmod(p.stat().st_mode | 0o600)


def fingerprint_bundle(bundle_path: Path, include_full_disk_hash: bool = True) -> dict[str, Any]:
    if not bundle_path.is_dir():
        raise GoldenGuestError(f"Bundle missing: {redact_text(str(bundle_path))}")
    files_info: list[dict[str, Any]] = []
    total_bytes = 0
    for index, file_path in enumerate(sorted(p for p in bundle_path.rglob("*") if p.is_file())):
        if file_path.is_symlink():
            raise SafetyError("Symlinks inside VM bundle are forbidden")
        rel = str(file_path.relative_to(bundle_path))
        if rel == EPHEMERAL_META_FILENAME:
            continue
        stat = file_path.stat()
        total_bytes += stat.st_size
        is_large_disk = file_path.suffix.lower() == ".qcow2" and not include_full_disk_hash
        digest = "skipped-fast-mode" if is_large_disk else sha256_file(file_path)
        files_info.append(
            {
                "artifact_alias": f"vm-file-{index}{file_path.suffix}",
                "relative_path": rel,
                "size_bytes": stat.st_size,
                "sha256": digest,
            }
        )
    aggregate_payload = json.dumps(
        [{"relative_path": f["relative_path"], "size_bytes": f["size_bytes"], "sha256": f["sha256"]} for f in files_info],
        sort_keys=True,
    ).encode("utf-8")
    cfg_path = bundle_path / "config.plist"
    return {
        "config_sha256": sha256_file(cfg_path) if cfg_path.is_file() else "",
        "bundle_sha256": sha256_bytes(aggregate_payload),
        "total_bytes": total_bytes,
        "file_count": len(files_info),
        "readonly": is_bundle_readonly(bundle_path),
        "files": files_info,
    }


def validate_qemu_profile(bundle_path: Path, profile: dict[str, Any]) -> dict[str, Any]:
    config = read_config_plist(bundle_path)
    expected = profile["qemu_profile"]
    displays = config.get("Display", [])
    display_hw = displays[0].get("Hardware") if displays else None
    system = config.get("System", {})
    qemu = config.get("QEMU", {})
    sharing = config.get("Sharing", {})
    input_cfg = config.get("Input", {})
    drives = config.get("Drive", [])

    disks_contained = all(
        d.get("ImageName")
        and Path(str(d["ImageName"])).name == str(d["ImageName"])
        and (bundle_path / "Data" / str(d["ImageName"])).is_file()
        and not (bundle_path / "Data" / str(d["ImageName"])).is_symlink()
        for d in drives
        if d.get("ImageType") == "Disk"
    )

    checks = {
        "backend_is_qemu": config.get("Backend") == expected["backend"],
        "display_hardware_ok": display_hw == expected["display_hardware"],
        "cpu_count_ok": system.get("CPUCount") == expected["cpu_count"],
        "memory_mib_ok": system.get("MemorySize") == expected["memory_mib"],
        "uefi_boot_enabled": bool(qemu.get("UEFIBoot")) == bool(expected["uefi_boot"]),
        "tpm_device_enabled": bool(qemu.get("TPMDevice")) == bool(expected["tpm_device"]),
        "hypervisor_enabled": bool(qemu.get("Hypervisor")) == bool(expected["hypervisor"]),
        "additional_arguments_empty": len(qemu.get("AdditionalArguments", [])) == 0,
        "directory_share_disabled": sharing.get("DirectoryShareMode") == expected["directory_share_mode"],
        "clipboard_sharing_disabled": bool(sharing.get("ClipboardSharing", False)) == bool(expected["clipboard_sharing"]),
        "usb_sharing_disabled": bool(input_cfg.get("UsbSharing", False)) == bool(expected["usb_sharing"]),
        "writable_disks_contained": disks_contained,
    }
    return {
        "passed": all(checks.values()),
        "checks": checks,
        "observed": {
            "backend": config.get("Backend"),
            "display_hardware": display_hw,
            "display_args_expected": expected["display_args_expected"],
            "cpu_count": system.get("CPUCount"),
            "memory_mib": system.get("MemorySize"),
            "uefi_boot": bool(qemu.get("UEFIBoot")),
            "tpm_device": bool(qemu.get("TPMDevice")),
            "directory_share_mode": sharing.get("DirectoryShareMode"),
            "clipboard_sharing": bool(sharing.get("ClipboardSharing", False)),
            "usb_sharing": bool(input_cfg.get("UsbSharing", False)),
        },
    }


def assert_not_primary(target: Path, primary: Path | None) -> None:
    if primary is None:
        return
    resolved_target = target.resolve()
    resolved_primary = primary.resolve()
    if resolved_target == resolved_primary:
        raise SafetyError("Refusing to operate on primary cold-backup vm-a")
    if (resolved_target / "config.plist").is_file() and (resolved_primary / "config.plist").is_file():
        if bundle_uuid(resolved_target) == bundle_uuid(resolved_primary):
            raise SafetyError("Target UUID matches primary cold-backup vm-a; refusing operation")


def assert_not_golden(target: Path, golden: Path | None) -> None:
    if golden is None:
        return
    resolved_target = target.resolve()
    resolved_golden = golden.resolve()
    if resolved_target == resolved_golden:
        raise SafetyError("Refusing to mutate or destroy sealed golden-win11-arm64-v1")
    if (resolved_target / "config.plist").is_file() and (resolved_golden / "config.plist").is_file():
        if bundle_uuid(resolved_target) == bundle_uuid(resolved_golden):
            raise SafetyError("Target UUID matches sealed golden-win11-arm64-v1; refusing operation")


def check_lease_and_processes(
    lease_path: Path = DEFAULT_LEASE_PATH,
    allow_held_lease: bool = False,
) -> dict[str, Any]:
    lease_status = "missing"
    lease_data: dict[str, Any] = {}
    if lease_path.is_file():
        lease_data = json.loads(lease_path.read_text(encoding="utf-8"))
        lease_status = str(lease_data.get("status", "unknown"))

    ps_res = subprocess.run(
        ["ps", "-axo", "pid=,comm="],
        capture_output=True,
        text=True,
        timeout=15,
    )
    active_workers: list[str] = []
    if ps_res.returncode == 0:
        for line in ps_res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                proc_name = Path(parts[1]).name
                if proc_name in ("QEMULauncher", "QEMURenderServer", "swtpm.0") or proc_name.startswith("qemu-system-"):
                    active_workers.append(f"{parts[0]}:{proc_name}")

    lease_ok = allow_held_lease or (lease_status in ("released", "missing"))
    workers_ok = len(active_workers) == 0
    return {
        "lease_status": lease_status,
        "lease_released_at": lease_data.get("released_at"),
        "active_qemu_workers": active_workers,
        "ready": lease_ok and workers_ok,
    }


def utmctl_status(vm_uuid: str, utmctl: Path = DEFAULT_UTMCTL) -> str:
    if not utmctl.is_file():
        return "utmctl-unavailable"
    res = subprocess.run([str(utmctl), "status", vm_uuid], capture_output=True, text=True, timeout=20)
    if res.returncode != 0:
        return "unregistered"
    return res.stdout.strip().lower()


def verify_apfs_volume(path: Path) -> None:
    target = path if path.exists() else path.parent
    res = subprocess.run(
        ["diskutil", "info", "-plist", str(target)],
        capture_output=True,
        timeout=20,
    )
    if res.returncode != 0:
        vol_mount = next((p for p in target.parents if p.parent.name == "Volumes"), None)
        if vol_mount is not None:
            res = subprocess.run(
                ["diskutil", "info", "-plist", str(vol_mount)],
                capture_output=True,
                timeout=20,
            )
    if res.returncode != 0:
        raise GoldenGuestError("Unable to inspect filesystem type for APFS clone")
    info = plistlib.loads(res.stdout)
    if info.get("FilesystemType") != "apfs":
        raise GoldenGuestError(f"APFS filesystem required, got: {info.get('FilesystemType')}")


def apfs_cow_clone_bundle(source: Path, destination: Path) -> float:
    if destination.exists():
        raise GoldenGuestError(f"Destination already exists: {redact_text(str(destination))}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    res = subprocess.run(
        ["cp", "-cR", str(source), str(destination)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    elapsed = round(time.monotonic() - t0, 4)
    if res.returncode != 0:
        raise GoldenGuestError(f"APFS cp -cR failed: {redact_text(res.stderr)}")
    return elapsed


def verify_golden(
    golden: Path,
    primary: Path | None = None,
    profile_path: Path = DEFAULT_PROFILE_PATH,
    guest_report_path: Path | None = None,
    smoke_report_path: Path | None = None,
    output_path: Path | None = None,
    fast_disk_hash: bool = False,
) -> dict[str, Any]:
    profile = load_profile(profile_path)
    if not golden.is_dir():
        raise GoldenGuestError(f"Golden bundle not found: {redact_text(str(golden))}")
    assert_not_primary(golden, primary)

    qemu_validation = validate_qemu_profile(golden, profile)
    if not qemu_validation["passed"]:
        raise GoldenGuestError(
            "Golden QEMU config validation failed: "
            + json.dumps(qemu_validation["checks"], sort_keys=True)
        )

    golden_fp = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
    primary_fp = (
        fingerprint_bundle(primary, include_full_disk_hash=not fast_disk_hash)
        if primary is not None and primary.is_dir()
        else None
    )

    guest_report: dict[str, Any] = {}
    if guest_report_path and guest_report_path.is_file():
        guest_report = json.loads(guest_report_path.read_text(encoding="utf-8"))

    smoke_report: dict[str, Any] = {}
    if smoke_report_path and smoke_report_path.is_file():
        smoke_report = json.loads(smoke_report_path.read_text(encoding="utf-8"))

    manifest = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "golden_id": profile["golden_id"],
        "status": "sealed_readonly" if golden_fp["readonly"] else "unsealed",
        "captured_at_utc": utc_now_iso(),
        "bundle_alias": golden.name,
        "guest_os": profile["guest_os"],
        "qemu_profile": qemu_validation["observed"],
        "qemu_checks": qemu_validation["checks"],
        "graphics_driver": {
            "provider": profile["graphics_driver"]["provider"],
            "source": profile["graphics_driver"]["source"],
            "driver_version": guest_report.get("graphics_driver", {}).get(
                "driver_version", profile["graphics_driver"]["driver_version"]
            ),
            "adapter_description": guest_report.get("graphics_driver", {}).get(
                "adapter_name", profile["graphics_driver"]["adapter_description"]
            ),
            "whql_ready": guest_report.get("graphics_driver", {}).get("whql_ready", False),
            "all_components_present": guest_report.get("graphics_driver", {}).get(
                "all_components_present", False
            ),
            "feature_level": smoke_report.get("feature_level", profile["graphics_driver"]["feature_level"]),
            "max_channel_error_lsb": smoke_report.get("max_channel_error_lsb"),
            "byte_exact_match": smoke_report.get("byte_exact_match"),
        },
        "security_invariants": guest_report.get("security_invariants", {}),
        "optimizer": {
            "profile_id": profile["optimizer"]["profile_id"],
            "rollback_snapshot_present": guest_report.get("optimizer", {}).get(
                "rollback_snapshot_present", False
            ),
        },
        "commercial_residue": guest_report.get("commercial_residue", {}),
        "fingerprints": {
            "sealed_readonly": golden_fp["readonly"],
            "golden_config_sha256": golden_fp["config_sha256"],
            "golden_bundle_sha256": golden_fp["bundle_sha256"],
            "golden_total_bytes": golden_fp["total_bytes"],
            "golden_file_count": golden_fp["file_count"],
            "primary_vm_a_config_sha256": primary_fp["config_sha256"] if primary_fp else None,
            "primary_vm_a_bundle_sha256": primary_fp["bundle_sha256"] if primary_fp else None,
            "primary_vm_a_total_bytes": primary_fp["total_bytes"] if primary_fp else None,
        },
        "smoke_metrics": smoke_report,
    }
    if output_path is not None:
        write_redacted_json(output_path, manifest)
    return manifest


def spawn_ephemeral(
    golden: Path,
    dest_dir: Path | None = None,
    name: str | None = None,
    primary: Path | None = None,
    register_utm: bool = False,
    utmctl: Path = DEFAULT_UTMCTL,
    skip_apfs_check: bool = False,
    fast_disk_hash: bool = False,
) -> dict[str, Any]:
    if not golden.is_dir():
        raise GoldenGuestError(f"Golden bundle not found: {redact_text(str(golden))}")
    assert_not_primary(golden, primary)
    if not is_bundle_readonly(golden):
        raise SafetyError("Golden bundle must be sealed read-only before spawning ephemeral clone")

    if not skip_apfs_check:
        verify_apfs_volume(golden)

    clone_name = name or f"ephemeral-{golden.stem}-{secrets.token_hex(4)}"
    if not re.match(r"^[A-Za-z0-9._-]+$", clone_name):
        raise GoldenGuestError("Invalid ephemeral clone name")
    parent_dir = dest_dir if dest_dir is not None else golden.parent
    ephemeral_path = parent_dir / f"{clone_name}.utm"
    assert_not_primary(ephemeral_path, primary)
    assert_not_golden(ephemeral_path, golden)

    golden_before = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
    clone_seconds = apfs_cow_clone_bundle(golden, ephemeral_path)
    set_bundle_readonly(ephemeral_path, readonly=False)

    new_uuid = str(uuid.uuid4()).upper()
    new_mac = generate_unicast_mac()
    config = read_config_plist(ephemeral_path)
    config.setdefault("Information", {})
    config["Information"]["UUID"] = new_uuid
    config["Information"]["Name"] = clone_name
    for nic in config.get("Network", []):
        nic["MacAddress"] = new_mac
    config["Sharing"] = {
        "ClipboardSharing": False,
        "DirectoryShareMode": "None",
        "DirectoryShareReadOnly": True,
    }
    config.setdefault("Input", {})["UsbSharing"] = False
    for drive in config.get("Drive", []):
        if drive.get("ImageType") != "Disk":
            drive.pop("ImageName", None)
    write_config_plist(ephemeral_path, config)

    meta = {
        "schema_version": 1,
        "role": "ephemeral_golden_clone",
        "owner": "@DNPMBHC",
        "created_at_utc": utc_now_iso(),
        "clone_name": clone_name,
        "clone_uuid": new_uuid,
        "mac_address": new_mac,
        "golden_config_sha256": golden_before["config_sha256"],
        "golden_bundle_sha256": golden_before["bundle_sha256"],
    }
    write_redacted_json(ephemeral_path / EPHEMERAL_META_FILENAME, meta)

    if register_utm:
        reg_res = subprocess.run(
            ["open", "-a", "UTM", str(ephemeral_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if reg_res.returncode != 0:
            raise GoldenGuestError("Failed to register ephemeral clone in UTM")
        for _ in range(20):
            if utmctl_status(new_uuid, utmctl) != "unregistered":
                break
            time.sleep(0.5)

    golden_after = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
    if golden_after != golden_before:
        raise SafetyError("Golden bundle fingerprint drifted during spawn-ephemeral")

    return {
        "action": "spawn-ephemeral",
        "ephemeral_path": str(ephemeral_path),
        "clone_name": clone_name,
        "clone_uuid": new_uuid,
        "mac_address": new_mac,
        "clone_seconds": clone_seconds,
        "golden_untouched": True,
        "registered_in_utm": register_utm,
    }


def destroy_ephemeral(
    ephemeral_path: Path,
    golden: Path | None = None,
    primary: Path | None = None,
    baseline_manifest_path: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    fast_disk_hash: bool = False,
) -> dict[str, Any]:
    assert_not_primary(ephemeral_path, primary)
    assert_not_golden(ephemeral_path, golden)

    if not ephemeral_path.is_dir():
        raise GoldenGuestError(f"Ephemeral bundle not found: {redact_text(str(ephemeral_path))}")

    meta_path = ephemeral_path / EPHEMERAL_META_FILENAME
    if not meta_path.is_file():
        raise SafetyError("Refusing to delete bundle without .ephemeral-meta.json marker")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    if meta.get("role") != "ephemeral_golden_clone":
        raise SafetyError("Invalid ephemeral clone role marker; refusing deletion")

    clone_uuid = str(meta.get("clone_uuid") or bundle_uuid(ephemeral_path))
    state = utmctl_status(clone_uuid, utmctl)
    if state not in ("unregistered", "stopped", "utmctl-unavailable"):
        subprocess.run([str(utmctl), "stop", clone_uuid, "--request"], capture_output=True, text=True, timeout=30)
        for _ in range(30):
            state = utmctl_status(clone_uuid, utmctl)
            if state in ("stopped", "unregistered"):
                break
            time.sleep(1.0)
        if state not in ("stopped", "unregistered"):
            raise GoldenGuestError("Ephemeral VM failed to stop cleanly before destruction")

    if state == "stopped" and utmctl.is_file():
        del_res = subprocess.run([str(utmctl), "delete", clone_uuid], capture_output=True, text=True, timeout=30)
        if del_res.returncode != 0:
            raise GoldenGuestError("utmctl delete failed for ephemeral clone")

    if ephemeral_path.exists():
        set_bundle_readonly(ephemeral_path, readonly=False)
        shutil.rmtree(ephemeral_path)

    drift_report: dict[str, Any] = {
        "ephemeral_deleted": not ephemeral_path.exists(),
        "golden_zero_drift": None,
        "primary_zero_drift": None,
    }

    baseline_fp: dict[str, Any] = {}
    if baseline_manifest_path and baseline_manifest_path.is_file():
        baseline_fp = json.loads(baseline_manifest_path.read_text(encoding="utf-8")).get("fingerprints", {})

    if golden is not None and golden.is_dir():
        g_fp = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
        expected_cfg = meta.get("golden_config_sha256") or baseline_fp.get("golden_config_sha256")
        expected_bundle = meta.get("golden_bundle_sha256") or baseline_fp.get("golden_bundle_sha256")
        g_ok = g_fp["readonly"]
        if expected_cfg:
            g_ok = g_ok and (g_fp["config_sha256"] == expected_cfg)
        if expected_bundle:
            g_ok = g_ok and (g_fp["bundle_sha256"] == expected_bundle)
        drift_report["golden_zero_drift"] = g_ok
        if not g_ok:
            raise SafetyError("Golden bundle drift detected after ephemeral destruction")

    if primary is not None and primary.is_dir():
        p_fp = fingerprint_bundle(primary, include_full_disk_hash=not fast_disk_hash)
        expected_p_cfg = baseline_fp.get("primary_vm_a_config_sha256")
        expected_p_bundle = baseline_fp.get("primary_vm_a_bundle_sha256")
        p_ok = True
        if expected_p_cfg:
            p_ok = p_ok and (p_fp["config_sha256"] == expected_p_cfg)
        if expected_p_bundle:
            p_ok = p_ok and (p_fp["bundle_sha256"] == expected_p_bundle)
        drift_report["primary_zero_drift"] = p_ok
        if not p_ok:
            raise SafetyError("Primary vm-a drift detected after ephemeral destruction")

    return {
        "action": "destroy-ephemeral",
        "clone_name": meta.get("clone_name"),
        **drift_report,
    }


def prepare_golden_from_primary(
    primary: Path,
    golden_dest: Path,
    profile_path: Path = DEFAULT_PROFILE_PATH,
    lease_path: Path = DEFAULT_LEASE_PATH,
    skip_apfs_check: bool = False,
) -> dict[str, Any]:
    lease = check_lease_and_processes(lease_path=lease_path, allow_held_lease=False)
    if not lease["ready"]:
        raise SafetyError(f"VM lease or active QEMU workers block golden build: {lease}")
    if not primary.is_dir():
        raise GoldenGuestError("Primary vm-a bundle not found")
    assert_not_primary(golden_dest, primary)
    if not skip_apfs_check:
        verify_apfs_volume(primary)

    profile = load_profile(profile_path)
    expected = profile["qemu_profile"]
    primary_before = fingerprint_bundle(primary, include_full_disk_hash=False)
    clone_seconds = apfs_cow_clone_bundle(primary, golden_dest)
    set_bundle_readonly(golden_dest, readonly=False)

    config = read_config_plist(golden_dest)
    config.setdefault("Information", {})
    config["Information"]["UUID"] = str(uuid.uuid4()).upper()
    config["Information"]["Name"] = profile["golden_id"]
    config.setdefault("Display", [{}])
    config["Display"][0]["Hardware"] = expected["display_hardware"]
    config.setdefault("System", {})
    config["System"]["CPUCount"] = expected["cpu_count"]
    config["System"]["MemorySize"] = expected["memory_mib"]
    config.setdefault("QEMU", {})
    config["QEMU"]["UEFIBoot"] = bool(expected["uefi_boot"])
    config["QEMU"]["TPMDevice"] = bool(expected["tpm_device"])
    config["QEMU"]["Hypervisor"] = bool(expected["hypervisor"])
    config["QEMU"]["AdditionalArguments"] = []
    config["Sharing"] = {
        "ClipboardSharing": bool(expected["clipboard_sharing"]),
        "DirectoryShareMode": expected["directory_share_mode"],
        "DirectoryShareReadOnly": True,
    }
    config.setdefault("Input", {})["UsbSharing"] = bool(expected["usb_sharing"])
    for nic in config.get("Network", []):
        nic["MacAddress"] = generate_unicast_mac()
    for drive in config.get("Drive", []):
        if drive.get("ImageType") != "Disk":
            drive.pop("ImageName", None)
    write_config_plist(golden_dest, config)

    primary_after = fingerprint_bundle(primary, include_full_disk_hash=False)
    if primary_after != primary_before:
        raise SafetyError("Primary vm-a changed during golden staging")

    return {
        "action": "prepare-golden",
        "golden_path": str(golden_dest),
        "golden_uuid": config["Information"]["UUID"],
        "clone_seconds": clone_seconds,
        "primary_untouched": True,
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Golden Guest v1 manager (@DNPMBHC)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_lease = sub.add_parser("check-lease", help="Check 5C VM lease and active QEMU workers")
    p_lease.add_argument("--lease", type=Path, default=DEFAULT_LEASE_PATH)

    p_verify = sub.add_parser("verify-golden", help="Verify sealed golden image and emit manifest")
    p_verify.add_argument("--golden", type=Path, required=True)
    p_verify.add_argument("--primary", type=Path, default=None)
    p_verify.add_argument("--profile", type=Path, default=DEFAULT_PROFILE_PATH)
    p_verify.add_argument("--guest-report", type=Path, default=None)
    p_verify.add_argument("--smoke-report", type=Path, default=None)
    p_verify.add_argument("--output", type=Path, default=None)
    p_verify.add_argument("--fast-disk-hash", action="store_true")

    p_spawn = sub.add_parser("spawn-ephemeral", help="APFS CoW clone from sealed golden image")
    p_spawn.add_argument("--golden", type=Path, required=True)
    p_spawn.add_argument("--dest-dir", type=Path, default=None)
    p_spawn.add_argument("--name", type=str, default=None)
    p_spawn.add_argument("--primary", type=Path, default=None)
    p_spawn.add_argument("--register-utm", action="store_true")
    p_spawn.add_argument("--fast-disk-hash", action="store_true")

    p_destroy = sub.add_parser("destroy-ephemeral", help="Stop, unregister, and delete ephemeral clone")
    p_destroy.add_argument("--ephemeral", type=Path, required=True)
    p_destroy.add_argument("--golden", type=Path, default=None)
    p_destroy.add_argument("--primary", type=Path, default=None)
    p_destroy.add_argument("--manifest", type=Path, default=None)
    p_destroy.add_argument("--fast-disk-hash", action="store_true")

    p_seal = sub.add_parser("seal-readonly", help="Seal golden bundle read-only")
    p_seal.add_argument("--golden", type=Path, required=True)
    p_seal.add_argument("--primary", type=Path, default=None)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.command == "check-lease":
        result = check_lease_and_processes(lease_path=args.lease)
    elif args.command == "verify-golden":
        result = verify_golden(
            golden=args.golden,
            primary=args.primary,
            profile_path=args.profile,
            guest_report_path=args.guest_report,
            smoke_report_path=args.smoke_report,
            output_path=args.output,
            fast_disk_hash=args.fast_disk_hash,
        )
    elif args.command == "spawn-ephemeral":
        result = spawn_ephemeral(
            golden=args.golden,
            dest_dir=args.dest_dir,
            name=args.name,
            primary=args.primary,
            register_utm=args.register_utm,
            fast_disk_hash=args.fast_disk_hash,
        )
    elif args.command == "destroy-ephemeral":
        result = destroy_ephemeral(
            ephemeral_path=args.ephemeral,
            golden=args.golden,
            primary=args.primary,
            baseline_manifest_path=args.manifest,
            fast_disk_hash=args.fast_disk_hash,
        )
    elif args.command == "seal-readonly":
        assert_not_primary(args.golden, args.primary)
        set_bundle_readonly(args.golden, readonly=True)
        result = {"action": "seal-readonly", "readonly": is_bundle_readonly(args.golden)}
    else:
        raise GoldenGuestError(f"Unknown command: {args.command}")
    print(json.dumps(redact_value(result), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

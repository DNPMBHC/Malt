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
import copy
import fcntl
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import socket
import stat
import subprocess
import tempfile
import time
from typing import Any
from xml.parsers.expat import ExpatError
import uuid

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
def embedded_runtime_paths(script_dir: Path, home: Path | None = None) -> dict[str, Path] | None:
    """Keep writable runtime state out of a relocated, code-signed application bundle."""
    if script_dir.name != "RuntimeScripts" or script_dir.parent.name != "Resources":
        return None
    if script_dir.parent.parent.name != "Contents":
        return None
    support = (home or Path.home()) / "Library" / "Application Support" / "demo-app" / "Runtime"
    return {
        "profile": script_dir / "profiles" / "guest-profile.json",
        "lease": support / "State" / "vm-lease.json",
        "bridge": script_dir / "network",
    }


_EMBEDDED_PATHS = embedded_runtime_paths(SCRIPT_DIR)
if _EMBEDDED_PATHS is not None:
    DEFAULT_PROFILE_PATH = _EMBEDDED_PATHS["profile"]
    DEFAULT_LEASE_PATH = _EMBEDDED_PATHS["lease"]
else:
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
PLAYABLE_META_FILENAME = ".playable-meta.json"
DEFAULT_SOUND_HARDWARE = "intel-hda"
SUPPORTED_SOUND_HARDWARES: tuple[str, ...] = ("intel-hda", "virtio-sound-pci")
ALLOWED_RAM_MB: tuple[int, ...] = (6144, 8192, 10240, 12288)
DEFAULT_PLAYABLE_RAM_MB = 10240
DEFAULT_RENDERER_FPS_LIMIT = 120
DEFAULT_METAL_DRAWABLE_COUNT = 3
SUPPORTED_NETWORK_MODES: tuple[str, ...] = ("vmnet-shared", "socket-vmnet", "socket-stream", "emulated")
DEFAULT_PLAYABLE_NETWORK_MODE = "vmnet-shared"
SUPPORTED_DISK_INTERFACES: tuple[str, ...] = ("virtio", "nvme")
DEFAULT_PLAYABLE_DISK_INTERFACE = "virtio"
DEFAULT_IO_QUEUES = 4
ALLOWED_NET_RX_QUEUE_SIZES: tuple[int, ...] = (256, 512, 1024)
DEFAULT_NET_RX_QUEUE_SIZE = 1024
MALT_VMNET_BRIDGE_PLIST = Path("/Library/LaunchDaemons/com.malt.vmnet-bridge.plist")
MALT_VMNET_BRIDGE_SOCKETS: tuple[Path, ...] = (
    Path("/var/run/malt-vmnet-bridge.sock"),
    Path("/tmp/malt-vmnet-bridge.sock"),
)
MALT_VMNET_BRIDGE_DIR = WORKSPACE_ROOT / "Whisky" / "Modules" / "utm-custom" / "vmnet-bridge"
if _EMBEDDED_PATHS is not None:
    MALT_VMNET_BRIDGE_DIR = _EMBEDDED_PATHS["bridge"]
FORBIDDEN_QEMU_ARG_RE = re.compile(
    r"(?:kvm\s*=\s*off|\bhv_vendor_id\b|hypervisor\.cpuid\.v0|-smbios\b|-acpitable\b|\b-qmp\b|\b-gdb\b)",
    re.IGNORECASE,
)
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
        r"(?<![\w.])/(?:Users|(?:private/)?var/folders)/[^\s\"'<>`]+",
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
        if _EMBEDDED_PATHS is not None and profile_path == DEFAULT_PROFILE_PATH:
            raise GoldenGuestError(
                "Guest environment is not configured. Import a licensed guest image and its profile; "
                "this application does not include a preconfigured guest disk."
            )
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
        if rel in (EPHEMERAL_META_FILENAME, PLAYABLE_META_FILENAME):
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


SUPPORTED_DX_DRIVERS: dict[str, int] = {"D3DMetal": 0, "DXMT": 2}


def detect_apple_silicon_p_cores() -> int:
    """Detect host Apple Silicon performance core count; fallback safely to 4..6."""
    try:
        res = subprocess.run(
            ["sysctl", "-n", "hw.perflevel0.physicalcpu"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            val = int(res.stdout.strip())
            if 1 <= val <= 32:
                return val
    except Exception:
        pass
    return max(2, min(6, os.cpu_count() or 4))


def detect_recommended_vcpu() -> int:
    """Recommend Guest vCPU count based on Phase 12A 6/7/8 vCPU real-machine A/B benchmark.

    On 10-core Apple Silicon (4P+6E) hosts, 8 vCPU achieved the highest composite score
    (breaking the 6-vCPU ceiling while leaving 2 cores for macOS and QEMURenderServer).
    """
    p_cores = detect_apple_silicon_p_cores()
    total = os.cpu_count() or p_cores
    if total >= 10:
        return min(8, max(p_cores, total - 2))
    if p_cores >= 6:
        return min(p_cores, 8)
    return max(4, min(6, total - 2))


def secure_vmnet_socket(path: Path, *, current_uid: int | None = None) -> bool:
    """Check the restricted bridge endpoint without starting a guest network session."""
    uid = os.getuid() if current_uid is None else current_uid
    if uid < 501:
        return False
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISSOCK(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == uid


def _entitlement_enabled(output: str, key: str) -> bool:
    """A false entitlement or an error mentioning its name does not grant permission."""
    start = output.find("<?xml")
    if start < 0:
        start = output.find("<plist")
    end = output.find("</plist>", start)
    if start < 0 or end < 0:
        return False
    try:
        values = plistlib.loads(output[start:end + len("</plist>")].encode())
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        return False
    return isinstance(values, dict) and values.get(key) is True


def detect_host_network_capabilities(
    utm_app: Path = Path("/Applications/UTM.app"),
    bridge_socket_override: Path | None = None,
) -> dict[str, Any]:
    """Read-only probe of host vmnet entitlement, malt-vmnet-bridge daemon, and socket_vmnet availability."""
    launcher = utm_app / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app"
    official_vmnet_entitled = False
    if launcher.exists():
        try:
            res = subprocess.run(
                ["codesign", "-d", "--entitlements", "-", str(launcher)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            combined = (res.stdout or "") + "\n" + (res.stderr or "")
            official_vmnet_entitled = res.returncode == 0 and _entitlement_enabled(
                combined, "com.apple.vm.networking"
            )
        except Exception:
            official_vmnet_entitled = False

    bridge_candidates: list[Path] = []
    if bridge_socket_override is not None:
        bridge_candidates.append(bridge_socket_override)
    env_bridge_sock = os.environ.get("MALT_VMNET_BRIDGE_SOCKET", "").strip()
    if env_bridge_sock:
        bridge_candidates.append(Path(env_bridge_sock))
    bridge_candidates.extend(MALT_VMNET_BRIDGE_SOCKETS)
    malt_bridge_active_sock = next(
        (str(p) for p in bridge_candidates if secure_vmnet_socket(p)),
        None,
    )
    malt_bridge_source_ready = (
        (MALT_VMNET_BRIDGE_DIR / "malt_vmnet_bridge.c").is_file()
        and (MALT_VMNET_BRIDGE_DIR / "com.malt.vmnet-bridge.plist.template").is_file()
        and (MALT_VMNET_BRIDGE_DIR / "install_vmnet_bridge.sh").is_file()
    )

    socket_vmnet_bins = [
        Path("/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet"),
        Path("/usr/local/opt/socket_vmnet/bin/socket_vmnet"),
    ]
    socket_vmnet_socks = [
        Path("/var/run/socket_vmnet"),
        Path("/opt/homebrew/var/run/socket_vmnet"),
    ]
    socket_vmnet_installed = any(p.is_file() for p in socket_vmnet_bins)
    socket_vmnet_active_sock = next(
        (str(p) for p in socket_vmnet_socks if p.is_socket() and os.access(p, os.R_OK | os.W_OK)), None
    )

    active_daemon_sock = malt_bridge_active_sock or socket_vmnet_active_sock
    recommended_mode = (
        "vmnet-shared"
        if official_vmnet_entitled
        else ("socket-vmnet" if active_daemon_sock else "socket-stream")
    )
    adhoc_recommended_mode = "socket-vmnet" if active_daemon_sock else "socket-stream"
    return {
        "official_utm_vmnet_entitled": official_vmnet_entitled,
        "malt_vmnet_bridge_source_ready": malt_bridge_source_ready,
        "malt_vmnet_bridge_plist_installed": MALT_VMNET_BRIDGE_PLIST.is_file(),
        "malt_vmnet_bridge_socket_active": malt_bridge_active_sock is not None,
        "malt_vmnet_bridge_socket_path": malt_bridge_active_sock,
        "socket_vmnet_installed": socket_vmnet_installed,
        "socket_vmnet_socket_active": socket_vmnet_active_sock is not None,
        "socket_vmnet_socket_path": socket_vmnet_active_sock,
        "active_vmnet_daemon_socket": active_daemon_sock,
        "recommended_native_mode": recommended_mode,
        "adhoc_recommended_mode": adhoc_recommended_mode,
        "adhoc_sandbox_compatible_mode": "socket-stream",
    }


def resolve_effective_network_config(
    *,
    utm_app: Path = Path("/Applications/UTM.app"),
    prefer_adhoc: bool = False,
    fallback_stream_endpoint: str = "127.0.0.1:18443",
    bridge_socket_override: Path | None = None,
) -> dict[str, Any]:
    """Select the highest-performance non-slirp network pipeline available on this host.

    Priority:
      1. `vmnet-shared` when running an entitled UTM/Malt build (unless prefer_adhoc=True).
      2. `socket-vmnet` when `malt-vmnet-bridge` or `socket_vmnet` LaunchDaemon is active
         (zero paid signing, zero SIP disable, full kernel TCP/UDP/ICMP vmnet.framework).
      3. `socket-stream` full TCP+UDP+ICMP zero-privilege high-QoS async proxy fallback.
    """
    caps = detect_host_network_capabilities(
        utm_app=utm_app,
        bridge_socket_override=bridge_socket_override,
    )
    if not prefer_adhoc and caps["official_utm_vmnet_entitled"]:
        return {
            "network_mode": "vmnet-shared",
            "socket_endpoint": None,
            "reason": "entitled_vmnet_framework",
            "capabilities": caps,
        }
    if caps["active_vmnet_daemon_socket"]:
        daemon_kind = (
            "malt-vmnet-bridge"
            if caps["malt_vmnet_bridge_socket_active"]
            else "socket_vmnet"
        )
        return {
            "network_mode": "socket-vmnet",
            "socket_endpoint": caps["active_vmnet_daemon_socket"],
            "reason": f"daemon_kernel_vmnet_{daemon_kind}",
            "capabilities": caps,
        }
    return {
        "network_mode": "socket-stream",
        "socket_endpoint": fallback_stream_endpoint,
        "reason": "zero_privilege_full_tcp_udp_icmp_proxy_fallback",
        "capabilities": caps,
    }


def _parse_socket_endpoint(endpoint: str) -> dict[str, str]:
    raw = str(endpoint).strip()
    if not raw:
        raise GoldenGuestError("socket_endpoint cannot be empty for socket-vmnet / socket-stream mode")
    if raw.startswith("unix://"):
        sock_path = raw[len("unix://"):]
        if not sock_path.startswith("/") or any(c in sock_path for c in (",", " ", "\n", "\r")):
            raise GoldenGuestError("Invalid unix socket endpoint path")
        return {"kind": "unix", "path": sock_path}
    if raw.startswith("/"):
        if any(c in raw for c in (",", " ", "\n", "\r")):
            raise GoldenGuestError("Invalid unix socket endpoint path")
        return {"kind": "unix", "path": raw}
    cleaned = raw[len("tcp://"):] if raw.startswith("tcp://") else raw
    if ":" not in cleaned:
        raise GoldenGuestError("TCP socket_endpoint must be formatted as host:port (e.g. 127.0.0.1:18443)")
    host, port_str = cleaned.rsplit(":", 1)
    if not re.match(r"^[A-Za-z0-9._-]+$", host):
        raise GoldenGuestError("Invalid host in socket_endpoint")
    try:
        port = int(port_str)
    except ValueError as exc:
        raise GoldenGuestError("Invalid port in socket_endpoint") from exc
    if not (1 <= port <= 65535):
        raise GoldenGuestError("socket_endpoint port must be in 1..65535")
    return {"kind": "inet", "host": host, "port": str(port)}


def _assert_safe_qemu_args(args: list[str]) -> None:
    joined = " ".join(args)
    if FORBIDDEN_QEMU_ARG_RE.search(joined):
        raise SafetyError("Refusing forbidden QEMU spoofing or debug argument in AdditionalArguments")


def _upsert_qemu_arg_pair(args: list[str], flag: str, value: str, match_prefix: str) -> list[str]:
    """Replace an existing flag/value pair matching match_prefix, or append a new pair."""
    out: list[str] = []
    i = 0
    replaced = False
    while i < len(args):
        if (
            i + 1 < len(args)
            and args[i] == flag
            and args[i + 1].startswith(match_prefix)
        ):
            if not replaced:
                out.extend([flag, value])
                replaced = True
            i += 2
            continue
        out.append(args[i])
        i += 1
    if not replaced:
        out.extend([flag, value])
    return out


def trim_ephemeral_utm_config(
    config: dict[str, Any],
    *,
    trim_hardware: bool = True,
    no_sound: bool = False,
    sound_hardware: str | None = None,
    dx_driver: str | None = None,
    fps_limit: int | None = None,
    ram_mb: int | None = None,
    vcpu: int | None = None,
    disable_balloon: bool = False,
    pure_relative_mouse: bool = False,
    virtio_mouse: bool = False,
    disable_usb_redir: bool | None = None,
    iosurface_direct_present: bool | None = None,
    network_mode: str | None = None,
    socket_endpoint: str | None = None,
    net_rx_queue_size: int | None = None,
    disk_interface: str | None = None,
    enable_iothread: bool = False,
    io_queues: int | None = None,
) -> dict[str, Any]:
    """Apply safe UTM virtual hardware trimming, de-emulation (virtio-mouse-pci, zero usb-redir),
    sound policy, native/non-slirp network, IOSurface direct-present metadata, and CPU/RAM/IO tuning."""
    removed_cdroms = 0
    effective_disable_usb_redir = trim_hardware if disable_usb_redir is None else bool(disable_usb_redir)
    if trim_hardware:
        config["Sharing"] = {
            "ClipboardSharing": False,
            "DirectoryShareMode": "None",
            "DirectoryShareReadOnly": True,
        }
        input_cfg = config.setdefault("Input", {})
        input_cfg["UsbSharing"] = False
        input_cfg.pop("MaximumUsbShares", None)
        input_cfg["MaximumUsbShare"] = 0

        displays = config.get("Display", [])
        if isinstance(displays, list) and displays:
            displays[0]["DynamicResolution"] = False

        original_drives = config.get("Drive", [])
        kept_drives: list[dict[str, Any]] = []
        for drive in original_drives:
            is_disk = drive.get("ImageType") == "Disk"
            has_image = bool(drive.get("ImageName"))
            if is_disk or has_image:
                kept_drives.append(drive)
            else:
                removed_cdroms += 1
        config["Drive"] = kept_drives

    if effective_disable_usb_redir:
        input_cfg = config.setdefault("Input", {})
        input_cfg["UsbSharing"] = False
        input_cfg.pop("MaximumUsbShares", None)
        input_cfg["MaximumUsbShare"] = 0
        input_cfg["DisableUsbRedir"] = True

    if iosurface_direct_present is not None:
        displays = config.get("Display", [])
        if isinstance(displays, list) and displays:
            displays[0]["IOSurfaceDirectPresent"] = bool(iosurface_direct_present)

    # Sound policy: retain/provision standard intel-hda (+ hda-duplex) by default;
    # allow explicit evaluation of virtio-sound-pci; strip sound only when --no-sound is requested.
    if sound_hardware is not None and sound_hardware not in SUPPORTED_SOUND_HARDWARES:
        raise GoldenGuestError(
            f"Unsupported sound_hardware '{sound_hardware}'; expected one of {SUPPORTED_SOUND_HARDWARES}"
        )
    if no_sound:
        config["Sound"] = []
    elif sound_hardware is not None:
        config["Sound"] = [{"Hardware": sound_hardware}]
    else:
        existing_sound = config.get("Sound")
        if not isinstance(existing_sound, list) or len(existing_sound) == 0:
            config["Sound"] = [{"Hardware": DEFAULT_SOUND_HARDWARE}]

    if ram_mb is not None:
        if int(ram_mb) not in ALLOWED_RAM_MB:
            raise GoldenGuestError(
                f"Unsupported ram_mb '{ram_mb}'; expected one of {ALLOWED_RAM_MB}"
            )
        config.setdefault("System", {})["MemorySize"] = int(ram_mb)

    if vcpu is not None:
        if int(vcpu) < 1 or int(vcpu) > 32:
            raise GoldenGuestError("vcpu must be an integer between 1 and 32")
        config.setdefault("System", {})["CPUCount"] = int(vcpu)

    if disable_balloon:
        config.setdefault("QEMU", {})["BalloonDevice"] = False

    if pure_relative_mouse or virtio_mouse:
        config.setdefault("Input", {})["PureRelativeMouse"] = True

    if virtio_mouse:
        config.setdefault("Input", {})["VirtioMouse"] = True
    elif "VirtioMouse" in config.get("Input", {}):
        config["Input"]["VirtioMouse"] = False

    if dx_driver is not None:
        if dx_driver not in SUPPORTED_DX_DRIVERS:
            raise GoldenGuestError(
                f"Unsupported DirectX driver '{dx_driver}'; expected one of {tuple(SUPPORTED_DX_DRIVERS.keys())}"
            )
        qemu_cfg = config.setdefault("QEMU", {})
        qemu_cfg["DirectXDriver"] = SUPPORTED_DX_DRIVERS[dx_driver]

    if fps_limit is not None:
        if fps_limit <= 0:
            raise GoldenGuestError("fps_limit must be a positive integer")
        qemu_cfg = config.setdefault("QEMU", {})
        qemu_cfg["RendererFPSLimit"] = int(fps_limit)
        qemu_cfg["QEMURendererFPSLimit"] = int(fps_limit)

    qemu_cfg = config.setdefault("QEMU", {})
    add_args = [str(a) for a in qemu_cfg.get("AdditionalArguments", [])]

    # Disk interface & VirtIO-Blk dedicated iothread + multi-queue tuning
    if disk_interface is not None:
        if disk_interface not in SUPPORTED_DISK_INTERFACES:
            raise GoldenGuestError(
                f"Unsupported disk_interface '{disk_interface}'; expected one of {SUPPORTED_DISK_INTERFACES}"
            )
        target_iface = "VirtIO" if disk_interface == "virtio" else "NVMe"
        for drive in config.get("Drive", []):
            if drive.get("ImageType") == "Disk":
                drive["Interface"] = target_iface

    if io_queues is not None:
        if int(io_queues) < 1 or int(io_queues) > 8:
            raise GoldenGuestError("io_queues must be an integer between 1 and 8")

    disk_interfaces_present = [
        str(d.get("Interface", ""))
        for d in config.get("Drive", [])
        if d.get("ImageType") == "Disk"
    ]
    has_virtio_disk = any(iface.lower() == "virtio" for iface in disk_interfaces_present)
    effective_io_queues: int | None = None
    virtio_blk_iothread_enabled = False
    if enable_iothread or (io_queues is not None and has_virtio_disk):
        if has_virtio_disk:
            effective_io_queues = int(io_queues) if io_queues is not None else DEFAULT_IO_QUEUES
            if enable_iothread:
                add_args = _upsert_qemu_arg_pair(add_args, "-object", "iothread,id=iothread0", "iothread,id=iothread0")
                add_args = _upsert_qemu_arg_pair(
                    add_args, "-global", "virtio-blk-pci.iothread=iothread0", "virtio-blk-pci.iothread="
                )
                virtio_blk_iothread_enabled = True
            add_args = _upsert_qemu_arg_pair(
                add_args, "-global", f"virtio-blk-pci.num-queues={effective_io_queues}", "virtio-blk-pci.num-queues="
            )

    # Network pipeline refactoring: vmnet-shared / socket-vmnet / socket-stream / emulated
    if net_rx_queue_size is not None and int(net_rx_queue_size) not in ALLOWED_NET_RX_QUEUE_SIZES:
        raise GoldenGuestError(
            f"Unsupported net_rx_queue_size '{net_rx_queue_size}'; expected one of {ALLOWED_NET_RX_QUEUE_SIZES}"
        )

    effective_network_mode = network_mode
    effective_rx_queue_size: int | None = None
    if network_mode is not None:
        if network_mode not in SUPPORTED_NETWORK_MODES:
            raise GoldenGuestError(
                f"Unsupported network_mode '{network_mode}'; expected one of {SUPPORTED_NETWORK_MODES}"
            )
        existing_nics = config.get("Network", [])
        mac_addr = (
            str(existing_nics[0].get("MacAddress"))
            if isinstance(existing_nics, list) and existing_nics and existing_nics[0].get("MacAddress")
            else generate_unicast_mac()
        )
        if network_mode == "vmnet-shared":
            config["Network"] = [
                {
                    "Hardware": "virtio-net-pci",
                    "IsolateFromHost": False,
                    "MacAddress": mac_addr,
                    "Mode": "Shared",
                    "PortForward": [],
                }
            ]
            effective_rx_queue_size = int(net_rx_queue_size or DEFAULT_NET_RX_QUEUE_SIZE)
            add_args = _upsert_qemu_arg_pair(
                add_args, "-global", "virtio-net-pci.ioeventfd=on", "virtio-net-pci.ioeventfd="
            )
            add_args = _upsert_qemu_arg_pair(
                add_args,
                "-global",
                f"virtio-net-pci.rx_queue_size={effective_rx_queue_size}",
                "virtio-net-pci.rx_queue_size=",
            )
        elif network_mode in ("socket-vmnet", "socket-stream"):
            if not socket_endpoint:
                raise GoldenGuestError(
                    f"network_mode '{network_mode}' requires --socket-endpoint (e.g. 127.0.0.1:18443 or /var/run/socket_vmnet)"
                )
            ep = _parse_socket_endpoint(socket_endpoint)
            # Empty Network[] prevents UTM from rejecting unsigned apps with vmnetNotEntitled
            # and allows AdditionalArguments to attach the non-slirp virtio-net-pci + stream backend.
            config["Network"] = []
            effective_rx_queue_size = int(net_rx_queue_size or DEFAULT_NET_RX_QUEUE_SIZE)
            if ep["kind"] == "inet":
                netdev_arg = f"stream,id=net0,server=off,addr.type=inet,addr.host={ep['host']},addr.port={ep['port']}"
            else:
                netdev_arg = f"stream,id=net0,server=off,addr.type=unix,path={ep['path']}"
            dev_arg = (
                f"virtio-net-pci,netdev=net0,mac={mac_addr},ioeventfd=on,"
                f"rx_queue_size={effective_rx_queue_size}"
            )
            add_args = _upsert_qemu_arg_pair(add_args, "-netdev", netdev_arg, "stream,id=net0,")
            add_args = _upsert_qemu_arg_pair(add_args, "-device", dev_arg, "virtio-net-pci,netdev=net0,")
        elif network_mode == "emulated":
            config["Network"] = [
                {
                    "Hardware": "virtio-net-pci",
                    "IsolateFromHost": False,
                    "MacAddress": mac_addr,
                    "Mode": "Emulated",
                    "PortForward": [],
                }
            ]
            if net_rx_queue_size is not None:
                effective_rx_queue_size = int(net_rx_queue_size)
                add_args = _upsert_qemu_arg_pair(
                    add_args, "-global", "virtio-net-pci.ioeventfd=on", "virtio-net-pci.ioeventfd="
                )
                add_args = _upsert_qemu_arg_pair(
                    add_args,
                    "-global",
                    f"virtio-net-pci.rx_queue_size={effective_rx_queue_size}",
                    "virtio-net-pci.rx_queue_size=",
                )
    else:
        existing_nics = config.get("Network", [])
        if isinstance(existing_nics, list) and existing_nics:
            m = str(existing_nics[0].get("Mode", "")).lower()
            effective_network_mode = "vmnet-shared" if m == "shared" else ("emulated" if m == "emulated" else m)

    _assert_safe_qemu_args(add_args)
    if add_args or "AdditionalArguments" in qemu_cfg:
        qemu_cfg["AdditionalArguments"] = add_args

    sound_devices = [
        str(item.get("Hardware", ""))
        for item in config.get("Sound", [])
        if isinstance(item, dict) and item.get("Hardware")
    ]
    return {
        "trim_hardware_applied": trim_hardware,
        "removed_empty_cdrom_slots": removed_cdroms,
        "dynamic_resolution_locked_false": bool(
            config.get("Display") and config["Display"][0].get("DynamicResolution") is False
        ),
        "usb_sharing_disabled": bool(config.get("Input", {}).get("UsbSharing") is False),
        "maximum_usb_share": config.get("Input", {}).get("MaximumUsbShare"),
        "maximum_usb_shares": config.get("Input", {}).get("MaximumUsbShare"),
        "usb_redir_disabled": bool(config.get("Input", {}).get("DisableUsbRedir", False)),
        "sound_enabled": len(sound_devices) > 0,
        "sound_devices": sound_devices,
        "memory_mib": config.get("System", {}).get("MemorySize"),
        "cpu_count": config.get("System", {}).get("CPUCount"),
        "balloon_device": config.get("QEMU", {}).get("BalloonDevice"),
        "pure_relative_mouse": bool(config.get("Input", {}).get("PureRelativeMouse", False)),
        "virtio_mouse": bool(config.get("Input", {}).get("VirtioMouse", False)),
        "iosurface_direct_present": bool(
            config.get("Display") and config["Display"][0].get("IOSurfaceDirectPresent", False)
        ),
        "directx_driver": config.get("QEMU", {}).get("DirectXDriver"),
        "renderer_fps_limit": config.get("QEMU", {}).get("RendererFPSLimit"),
        "triple_buffering_enabled": True,
        "metal_drawable_count": DEFAULT_METAL_DRAWABLE_COUNT,
        "network_mode": effective_network_mode,
        "net_rx_queue_size": effective_rx_queue_size,
        "disk_interfaces": disk_interfaces_present,
        "virtio_blk_iothread": virtio_blk_iothread_enabled,
        "virtio_blk_num_queues": effective_io_queues,
        "discard_unmap_expected": len(disk_interfaces_present) > 0,
        "additional_arguments_count": len(add_args),
    }


def spawn_ephemeral(
    golden: Path,
    dest_dir: Path | None = None,
    name: str | None = None,
    primary: Path | None = None,
    register_utm: bool = False,
    utmctl: Path = DEFAULT_UTMCTL,
    skip_apfs_check: bool = False,
    fast_disk_hash: bool = False,
    trim_hardware: bool = False,
    no_sound: bool = False,
    sound_hardware: str | None = None,
    dx_driver: str | None = None,
    fps_limit: int | None = None,
    ram_mb: int | None = None,
    vcpu: int | None = None,
    disable_balloon: bool = False,
    pure_relative_mouse: bool = False,
    virtio_mouse: bool = False,
    disable_usb_redir: bool | None = None,
    iosurface_direct_present: bool | None = None,
    network_mode: str | None = None,
    socket_endpoint: str | None = None,
    net_rx_queue_size: int | None = None,
    disk_interface: str | None = None,
    enable_iothread: bool = False,
    io_queues: int | None = None,
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
    trim_summary = trim_ephemeral_utm_config(
        config,
        trim_hardware=trim_hardware,
        no_sound=no_sound,
        sound_hardware=sound_hardware,
        dx_driver=dx_driver,
        fps_limit=fps_limit,
        ram_mb=ram_mb,
        vcpu=vcpu,
        disable_balloon=disable_balloon,
        pure_relative_mouse=pure_relative_mouse,
        virtio_mouse=virtio_mouse,
        disable_usb_redir=disable_usb_redir,
        iosurface_direct_present=iosurface_direct_present,
        network_mode=network_mode,
        socket_endpoint=socket_endpoint,
        net_rx_queue_size=net_rx_queue_size,
        disk_interface=disk_interface,
        enable_iothread=enable_iothread,
        io_queues=io_queues,
    )
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
        "trim_summary": trim_summary,
    }


def create_playable(
    golden: Path,
    dest_dir: Path | None = None,
    name: str = "playable-win11-arm64",
    primary: Path | None = None,
    reset: bool = False,
    register_utm: bool = False,
    utmctl: Path = DEFAULT_UTMCTL,
    skip_apfs_check: bool = False,
    fast_disk_hash: bool = False,
    trim_hardware: bool = True,
    no_sound: bool = False,
    sound_hardware: str | None = None,
    dx_driver: str | None = "DXMT",
    fps_limit: int | None = DEFAULT_RENDERER_FPS_LIMIT,
    ram_mb: int | None = DEFAULT_PLAYABLE_RAM_MB,
    vcpu: int | None = None,
    disable_balloon: bool = True,
    pure_relative_mouse: bool = True,
    virtio_mouse: bool = True,
    disable_usb_redir: bool = True,
    iosurface_direct_present: bool = True,
    network_mode: str | None = DEFAULT_PLAYABLE_NETWORK_MODE,
    socket_endpoint: str | None = None,
    net_rx_queue_size: int | None = DEFAULT_NET_RX_QUEUE_SIZE,
    disk_interface: str | None = DEFAULT_PLAYABLE_DISK_INTERFACE,
    enable_iothread: bool = True,
    io_queues: int | None = DEFAULT_IO_QUEUES,
) -> dict[str, Any]:
    """Create (or reset) a persistent daily-playable APFS CoW VM preserving C: launcher & zh-CN state."""
    if not golden.is_dir():
        raise GoldenGuestError(f"Golden bundle not found: {redact_text(str(golden))}")
    assert_not_primary(golden, primary)
    if not is_bundle_readonly(golden):
        raise SafetyError("Golden bundle must be sealed read-only before creating playable VM")
    if not re.match(r"^[A-Za-z0-9._-]+$", name):
        raise GoldenGuestError("Invalid playable VM name")
    if not skip_apfs_check:
        verify_apfs_volume(golden)

    parent_dir = dest_dir if dest_dir is not None else golden.parent
    playable_path = parent_dir / f"{name}.utm"
    assert_not_primary(playable_path, primary)
    assert_not_golden(playable_path, golden)

    was_reset = False
    if playable_path.exists():
        if not reset:
            raise GoldenGuestError(
                f"Playable VM already exists: {redact_text(str(playable_path))}; use launch-playable or pass --reset"
            )
        meta_path = playable_path / PLAYABLE_META_FILENAME
        if not meta_path.is_file():
            raise SafetyError("Refusing to reset bundle without .playable-meta.json marker")
        old_meta = json.loads(meta_path.read_text(encoding="utf-8"))
        if old_meta.get("role") != "playable_working_vm":
            raise SafetyError("Invalid playable VM role marker; refusing reset")
        old_uuid = str(old_meta.get("vm_uuid") or bundle_uuid(playable_path))
        state = utmctl_status(old_uuid, utmctl)
        if state not in ("unregistered", "stopped", "utmctl-unavailable"):
            subprocess.run([str(utmctl), "stop", old_uuid, "--request"], capture_output=True, text=True, timeout=30)
            for _ in range(30):
                state = utmctl_status(old_uuid, utmctl)
                if state in ("stopped", "unregistered"):
                    break
                time.sleep(1.0)
            if state not in ("stopped", "unregistered"):
                raise GoldenGuestError("Playable VM failed to stop cleanly before reset")
        if state == "stopped" and utmctl.is_file():
            subprocess.run([str(utmctl), "delete", old_uuid], capture_output=True, text=True, timeout=30)
        if playable_path.exists():
            set_bundle_readonly(playable_path, readonly=False)
            shutil.rmtree(playable_path)
        was_reset = True

    effective_vcpu = vcpu if vcpu is not None else detect_recommended_vcpu()
    golden_before = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
    clone_seconds = apfs_cow_clone_bundle(golden, playable_path)
    set_bundle_readonly(playable_path, readonly=False)

    new_uuid = str(uuid.uuid4()).upper()
    new_mac = generate_unicast_mac()
    config = read_config_plist(playable_path)
    config.setdefault("Information", {})
    config["Information"]["UUID"] = new_uuid
    config["Information"]["Name"] = name
    for nic in config.get("Network", []):
        nic["MacAddress"] = new_mac
    for drive in config.get("Drive", []):
        if drive.get("ImageType") != "Disk":
            drive.pop("ImageName", None)
    trim_summary = trim_ephemeral_utm_config(
        config,
        trim_hardware=trim_hardware,
        no_sound=no_sound,
        sound_hardware=sound_hardware,
        dx_driver=dx_driver,
        fps_limit=fps_limit,
        ram_mb=ram_mb,
        vcpu=effective_vcpu,
        disable_balloon=disable_balloon,
        pure_relative_mouse=pure_relative_mouse,
        virtio_mouse=virtio_mouse,
        disable_usb_redir=disable_usb_redir,
        iosurface_direct_present=iosurface_direct_present,
        network_mode=network_mode,
        socket_endpoint=socket_endpoint,
        net_rx_queue_size=net_rx_queue_size,
        disk_interface=disk_interface,
        enable_iothread=enable_iothread,
        io_queues=io_queues,
    )
    write_config_plist(playable_path, config)

    meta = {
        "schema_version": 1,
        "role": "playable_working_vm",
        "owner": "@DNPMBHC",
        "created_at_utc": utc_now_iso(),
        "vm_name": name,
        "vm_uuid": new_uuid,
        "mac_address": new_mac,
        "golden_config_sha256": golden_before["config_sha256"],
        "golden_bundle_sha256": golden_before["bundle_sha256"],
        "persistent_c_drive": True,
    }
    write_redacted_json(playable_path / PLAYABLE_META_FILENAME, meta)

    if register_utm:
        reg_res = subprocess.run(
            ["open", "-a", "UTM", str(playable_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if reg_res.returncode != 0:
            raise GoldenGuestError("Failed to register playable VM in UTM")
        for _ in range(20):
            if utmctl_status(new_uuid, utmctl) != "unregistered":
                break
            time.sleep(0.5)

    golden_after = fingerprint_bundle(golden, include_full_disk_hash=not fast_disk_hash)
    if golden_after != golden_before:
        raise SafetyError("Golden bundle fingerprint drifted during create-playable")

    return {
        "action": "create-playable",
        "playable_path": str(playable_path),
        "vm_name": name,
        "vm_uuid": new_uuid,
        "mac_address": new_mac,
        "clone_seconds": clone_seconds,
        "was_reset": was_reset,
        "golden_untouched": True,
        "registered_in_utm": register_utm,
        "trim_summary": trim_summary,
    }


def launch_playable(
    playable_path: Path,
    *,
    golden: Path | None = None,
    primary: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Register (if needed) and start a persistent daily-playable working VM."""
    assert_not_primary(playable_path, primary)
    assert_not_golden(playable_path, golden)
    if not playable_path.is_dir():
        raise GoldenGuestError(f"Playable VM bundle not found: {redact_text(str(playable_path))}")
    meta_path = playable_path / PLAYABLE_META_FILENAME
    if not meta_path.is_file():
        raise SafetyError("Refusing to launch bundle without .playable-meta.json marker")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    if meta.get("role") != "playable_working_vm":
        raise SafetyError("Invalid playable VM role marker; refusing launch")

    vm_uuid = str(meta.get("vm_uuid") or bundle_uuid(playable_path))
    if dry_run:
        return {
            "action": "launch-playable",
            "playable_path": str(playable_path),
            "vm_name": meta.get("vm_name"),
            "vm_uuid": vm_uuid,
            "dry_run": True,
            "started": False,
        }

    state = utmctl_status(vm_uuid, utmctl)
    if state == "unregistered":
        reg_res = subprocess.run(
            ["open", "-a", "UTM", str(playable_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if reg_res.returncode != 0:
            raise GoldenGuestError("Failed to register playable VM in UTM")
        for _ in range(20):
            state = utmctl_status(vm_uuid, utmctl)
            if state != "unregistered":
                break
            time.sleep(0.5)

    already_started = state == "started"
    if not already_started:
        start_res = subprocess.run(
            [str(utmctl), "start", vm_uuid],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if start_res.returncode != 0:
            raise GoldenGuestError(f"Failed to start playable VM: {redact_text(start_res.stderr)}")
        state = utmctl_status(vm_uuid, utmctl)

    return {
        "action": "launch-playable",
        "playable_path": str(playable_path),
        "vm_name": meta.get("vm_name"),
        "vm_uuid": vm_uuid,
        "already_started": already_started,
        "status": state,
        "started": state == "started" or already_started,
    }


NATIVE_NETWORK_BACKUP_FILENAME = ".native-network-backup.plist"


def _network_state(config: dict[str, Any]) -> dict[str, Any]:
    qemu = config.get("QEMU", {})
    return {
        "had_qemu": "QEMU" in config,
        "had_network": "Network" in config,
        "network": copy.deepcopy(config.get("Network", [])),
        "had_arguments": "AdditionalArguments" in qemu,
        "arguments": copy.deepcopy(qemu.get("AdditionalArguments", [])),
    }


def _network_state_sha256(config: dict[str, Any]) -> str:
    return sha256_bytes(plistlib.dumps(_network_state(config), sort_keys=True))


def _atomic_private_plist(path: Path, payload: dict[str, Any], mode: int = 0o600) -> None:
    handle = tempfile.NamedTemporaryFile(prefix=".network-", dir=path.parent, delete=False)
    temporary = Path(handle.name)
    try:
        with handle:
            os.fchmod(handle.fileno(), mode)
            plistlib.dump(payload, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class PlayableImportError(SafetyError):
    """Import refusal with a stable, privacy-safe client error code."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _import_refuse(code: str, message: str) -> None:
    raise PlayableImportError(code, message)


def _import_check_processes() -> None:
    """Inspect names only; never start an engine to query an unregistered VM."""
    try:
        result = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PlayableImportError("process_check_failed", "Cannot verify that runtime workers are stopped") from error
    if result.returncode != 0 or not result.stdout.strip():
        _import_refuse("process_check_failed", "Cannot verify that runtime workers are stopped")
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            _import_refuse("process_check_failed", "Process inspection returned an invalid result")
        name = Path(fields[1]).name.lower()
        if name.startswith("qemu") or name.startswith("swtpm"):
            _import_refuse("active_runtime", "Close all container runtimes completely before importing")


def _import_inspect_bundle(bundle: Path) -> None:
    count = 0
    def failed_walk(_error: OSError) -> None:
        _import_refuse("unsafe_path", "Cannot inspect every instance state entry")

    for directory, directories, files in os.walk(bundle, followlinks=False, onerror=failed_walk):
        for name in directories + files:
            count += 1
            if count > 10000:
                _import_refuse("invalid_configuration", "Instance contains too many runtime state entries")
            path = Path(directory) / name
            if path.is_symlink():
                _import_refuse("unsafe_path", "Symbolic links are not accepted inside an imported instance")
            lower = name.lower()
            if lower.endswith((".pid", ".lock")) or lower in {"qmp", "qmp.sock", "qmp.socket"}:
                _import_refuse("busy_lock", "Instance has runtime lock or process state; close it completely first")
            if lower.startswith(("suspend", "savedstate")) or lower.endswith((".sav", ".vmem", ".vmss", ".state")):
                _import_refuse("suspended_state", "Shut down the guest; a suspended instance cannot be imported")
            if lower == "snapshots.plist":
                try:
                    state = plistlib.loads(path.read_bytes())
                except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
                    raise PlayableImportError("invalid_configuration", "Cannot verify snapshot state") from error
                if not isinstance(state, dict):
                    _import_refuse("invalid_configuration", "Invalid snapshot state")
                if state.get("SuspendIdentifier"):
                    _import_refuse("suspended_state", "Shut down the guest; a suspended instance cannot be imported")


def _import_config_identity(config: Any, bundle: Path) -> str:
    if not isinstance(config, dict) or config.get("Backend") != "QEMU":
        _import_refuse("invalid_configuration", "Import requires a supported QEMU ARM64 instance")
    info, system = config.get("Information"), config.get("System")
    if not isinstance(info, dict) or not isinstance(system, dict):
        _import_refuse("invalid_configuration", "Instance identity or system configuration is missing")
    raw_uuid = info.get("UUID")
    if not isinstance(raw_uuid, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", raw_uuid):
        _import_refuse("invalid_configuration", "Instance UUID is invalid")
    if uuid.UUID(raw_uuid).int == 0 or system.get("Architecture") not in ("aarch64", "arm64"):
        _import_refuse("invalid_configuration", "Import requires a valid UUID and ARM64 architecture")
    qemu = config.get("QEMU", {})
    arguments = qemu.get("AdditionalArguments", []) if isinstance(qemu, dict) else None
    if not isinstance(arguments, list) or any(not isinstance(argument, str) for argument in arguments):
        _import_refuse("invalid_configuration", "Invalid QEMU command configuration")
    protected = re.compile(r"golden|template|backup|cold[- _]?backup|(?:^|[- _])vm-a(?:[. _-]|$)|模板|冷备|备份", re.I)
    if any(protected.search(name) for name in (bundle.name, str(info.get("Name", "")))):
        _import_refuse("protected_instance", "Templates and cold backups cannot become working instances")
    drives = config.get("Drive")
    if not isinstance(drives, list) or not drives or any(not isinstance(drive, dict) for drive in drives):
        _import_refuse("invalid_configuration", "Instance has no valid local disk configuration")
    disks = 0
    for drive in drives:
        image = drive.get("ImageName")
        if not image:
            if drive.get("ImageType") == "Disk":
                _import_refuse("invalid_configuration", "Working disks must be stored inside the instance")
            continue
        if not isinstance(image, str) or "\\" in image or Path(image).is_absolute() or ".." in Path(image).parts:
            _import_refuse("unsafe_path", "Drive paths must stay inside the instance Data directory")
        path = bundle / "Data" / image
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(bundle / "Data"):
            _import_refuse("unsafe_path", "Drive image is missing or outside the instance")
        if drive.get("ImageType") == "Disk":
            mode = path.stat()
            if drive.get("ReadOnly") or mode.st_uid != os.getuid() or not mode.st_mode & 0o200 or not os.access(path, os.W_OK):
                _import_refuse("invalid_configuration", "Working disks must be owned by the current user and writable")
            disks += 1
    if not disks:
        _import_refuse("invalid_configuration", "Instance requires a writable local working disk")
    return raw_uuid


def import_playable(
    playable_path: Path, *, confirmed_stopped: bool = False,
    golden: Path | None = None, primary: Path | None = None, dry_run: bool = False,
) -> dict[str, Any]:
    """Adopt only an explicitly selected stopped working VM without changing guest data.

    Local inspection supplements the user's explicit shutdown confirmation. No engine
    query, registration, launch, stop, copy, or guest configuration write is performed.
    """
    if not confirmed_stopped:
        _import_refuse("needs_confirmation", "Confirm that this working instance is completely shut down")
    bundle = Path(playable_path)
    if not bundle.is_absolute() or ".." in bundle.parts or bundle.suffix.lower() != ".utm":
        _import_refuse("unsafe_path", "Select an absolute instance bundle path")
    # Permit only the immutable macOS system aliases, never resolve user symlinks.
    if len(bundle.parts) > 1 and bundle.parts[1] in ("var", "tmp"):
        alias = Path("/") / bundle.parts[1]
        canonical = Path("/private") / bundle.parts[1]
        if alias.is_symlink() and alias.resolve() == canonical:
            bundle = Path("/private") / bundle.relative_to("/")
    if any(path.is_symlink() for path in (bundle, *bundle.parents)) or not bundle.is_dir():
        _import_refuse("unsafe_path", "Instance path must be a real directory without symbolic links")
    config_path, marker = bundle / "config.plist", bundle / PLAYABLE_META_FILENAME
    if not config_path.is_file() or config_path.is_symlink():
        _import_refuse("invalid_configuration", "Instance configuration is missing or unsafe")
    if os.path.lexists(bundle / EPHEMERAL_META_FILENAME):
        _import_refuse("conflicting_metadata", "An ephemeral instance cannot become a persistent working instance")
    try:
        assert_not_primary(bundle, primary)
        assert_not_golden(bundle, golden)
    except (GoldenGuestError, OSError, ValueError) as error:
        raise PlayableImportError("protected_instance", "Protected templates and cold backups cannot be imported") from error
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(bundle, flags | getattr(os, "O_DIRECTORY", 0))
    config_fd = None
    temporary = None
    try:
        initial_directory = os.fstat(directory_fd)
        if initial_directory.st_uid != os.getuid() or not initial_directory.st_mode & 0o200:
            _import_refuse("unsafe_path", "Instance must be owned by the current user and writable")
        config_fd = os.open("config.plist", flags, dir_fd=directory_fd)
        initial_config = os.fstat(config_fd)
        if not stat.S_ISREG(initial_config.st_mode) or initial_config.st_nlink != 1 or initial_config.st_uid != os.getuid() or not initial_config.st_mode & 0o200 or not os.access(config_path, os.W_OK):
            _import_refuse("invalid_configuration", "Configuration must be an owned writable regular file")
        try:
            fcntl.flock(config_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PlayableImportError("busy_lock", "Configuration is locked by another operation") from error
        with os.fdopen(os.dup(config_fd), "rb") as handle:
            original = handle.read(8 * 1024 * 1024 + 1)
        if len(original) > 8 * 1024 * 1024:
            _import_refuse("invalid_configuration", "Instance configuration exceeds the supported size")
        try:
            config = plistlib.loads(original)
        except (ValueError, plistlib.InvalidFileException, ExpatError) as error:
            raise PlayableImportError("invalid_configuration", "Instance configuration is not a valid property list") from error
        vm_uuid = _import_config_identity(config, bundle)
        _import_inspect_bundle(bundle)
        _import_check_processes()
        already_managed = os.path.lexists(marker)
        if already_managed:
            state = marker.lstat()
            if not stat.S_ISREG(state.st_mode) or state.st_nlink != 1 or stat.S_IMODE(state.st_mode) != 0o600 or state.st_uid != os.getuid():
                _import_refuse("conflicting_metadata", "Existing working-instance metadata is not a private regular file")
            try:
                existing = json.loads(marker.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeError) as error:
                raise PlayableImportError("conflicting_metadata", "Existing working-instance metadata cannot be verified") from error
            if not isinstance(existing, dict) or existing.get("schema_version") != 1 or existing.get("role") != "playable_working_vm" or existing.get("vm_uuid") != vm_uuid:
                _import_refuse("conflicting_metadata", "Existing working-instance metadata conflicts with this instance")
        _import_inspect_bundle(bundle)
        _import_check_processes()
        current_directory, current_config = bundle.stat(), config_path.stat()
        if (current_directory.st_dev, current_directory.st_ino) != (initial_directory.st_dev, initial_directory.st_ino) or (current_config.st_dev, current_config.st_ino) != (initial_config.st_dev, initial_config.st_ino) or config_path.read_bytes() != original:
            _import_refuse("config_changed", "Instance or configuration changed during import")
        _import_config_identity(config, bundle)
        if os.path.lexists(bundle / EPHEMERAL_META_FILENAME):
            _import_refuse("conflicting_metadata", "Instance metadata changed during import")
        if already_managed:
            current_marker = marker.lstat()
            if (current_marker.st_dev, current_marker.st_ino, current_marker.st_mode) != (state.st_dev, state.st_ino, state.st_mode) or json.loads(marker.read_text(encoding="utf-8")) != existing:
                _import_refuse("conflicting_metadata", "Working-instance metadata changed during import")
        if not already_managed and not dry_run:
            metadata = {"schema_version": 1, "role": "playable_working_vm", "owner": "@DNPMBHC",
                        "vm_uuid": vm_uuid, "origin": "explicit_stopped_import",
                        "persistent_c_drive": True, "confirmed_stopped": True,
                        "config_sha256_at_import": sha256_bytes(original), "created_at_utc": utc_now_iso()}
            candidate = ".playable-import-" + secrets.token_hex(12)
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=directory_fd)
            temporary = candidate
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump(metadata, handle, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            try:
                os.link(temporary, PLAYABLE_META_FILENAME, src_dir_fd=directory_fd, dst_dir_fd=directory_fd, follow_symlinks=False)
            except FileExistsError as error:
                raise PlayableImportError("conflicting_metadata", "Working-instance metadata appeared during import; nothing was overwritten") from error
            os.fsync(directory_fd)
        return {"action": "import-playable", "imported": not dry_run, "metadata_verified": not dry_run,
                "already_managed": already_managed, "vm_uuid": vm_uuid, "dry_run": dry_run}
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
                os.fsync(directory_fd)
            except FileNotFoundError:
                pass
        if config_fd is not None:
            os.close(config_fd)
        os.close(directory_fd)


def _assert_no_saved_guest_state(bundle: Path) -> None:
    """A stopped engine can still have saved state; inspect local state without mutating it."""
    for filename, field in (("snapshots.plist", "SuspendIdentifier"), ("view.plist", "Suspended")):
        path = bundle / filename
        if not os.path.lexists(path):
            continue
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise SafetyError("Cannot trust saved-state metadata; networking was not changed")
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
            with os.fdopen(fd, "rb") as handle:
                opened = os.fstat(handle.fileno())
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    raise SafetyError("Saved-state metadata changed; networking was not changed")
                data = handle.read(8 * 1024 * 1024 + 1)
            if len(data) > 8 * 1024 * 1024:
                raise SafetyError("Saved-state metadata exceeds the supported size")
            state = plistlib.loads(data)
        except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
            raise SafetyError("Cannot verify saved-state metadata; networking was not changed") from error
        if not isinstance(state, dict):
            raise SafetyError("Cannot verify saved-state metadata; networking was not changed")
        if filename == "snapshots.plist":
            suspended = field in state
        else:
            if field in state and type(state[field]) is not bool:
                raise SafetyError("Cannot verify legacy saved-state metadata; networking was not changed")
            suspended = state.get(field, False)
        if suspended:
            raise SafetyError("Instance retains suspended or saved state; resume it and shut down normally before changing networking")

    def failed_walk(_error: OSError) -> None:
        raise SafetyError("Cannot inspect saved-state files; networking was not changed")

    for directory, directories, files in os.walk(bundle, followlinks=False, onerror=failed_walk):
        for name in directories + files:
            lower = name.lower()
            if lower.startswith(("suspend", "savedstate")) or lower.endswith((".sav", ".vmem", ".vmss", ".state")):
                raise SafetyError("Instance retains suspended or saved state; shut it down normally before changing networking")


def configure_playable_network(
    playable_path: Path,
    *,
    restore: bool = False,
    golden: Path | None = None,
    primary: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    kernel_socket: Path = MALT_VMNET_BRIDGE_SOCKETS[0],
    dry_run: bool = False,
) -> dict[str, Any]:
    """Apply or restore only networking on an explicitly stopped managed playable VM.

    This operation never stops, starts, registers, or unlocks a guest. The saved state
    is private, local to the selected VM and verified against later edits before restore.
    """
    resolved_name = playable_path.resolve().name.lower()
    if "golden" in resolved_name or resolved_name == "vm-a.utm" or resolved_name.startswith("vm-a-"):
        raise SafetyError("Protected templates and cold backups cannot change networking")
    meta, vm_uuid = _validate_managed_vm_bundle(playable_path, golden=golden, primary=primary)
    if meta.get("role") != "playable_working_vm":
        raise SafetyError("Network configuration requires a persistent playable instance")
    config_path = playable_path / "config.plist"
    marker_path = playable_path / PLAYABLE_META_FILENAME
    backup_path = playable_path / NATIVE_NETWORK_BACKUP_FILENAME
    if any(path.is_symlink() for path in (config_path, marker_path, backup_path)):
        raise SafetyError("Symbolic links are not accepted for network state")
    if not os.access(config_path, os.W_OK) or not config_path.stat().st_mode & 0o200:
        raise SafetyError("Network configuration requires a writable playable instance")
    if utmctl_status(vm_uuid, utmctl) != "stopped":
        raise SafetyError("Stop this playable instance before changing networking; unknown state is not safe")
    _assert_no_saved_guest_state(playable_path)
    if not restore and not secure_vmnet_socket(kernel_socket):
        raise GoldenGuestError("Native network service is not approved or its restricted socket is not ready")

    with config_path.open("rb") as locked_config:
        fcntl.flock(locked_config, fcntl.LOCK_EX)
        original = locked_config.read()
        config = plistlib.loads(original)
        if str(config.get("Information", {}).get("UUID", "")) != vm_uuid:
            raise SafetyError("Playable marker and configuration UUID do not match")
        if not isinstance(config.get("QEMU", {}), dict):
            raise SafetyError("Invalid QEMU configuration")
        if restore:
            if not backup_path.is_file():
                raise GoldenGuestError("No saved network configuration exists for this instance")
            backup = plistlib.loads(backup_path.read_bytes())
            if backup.get("vm_uuid") != vm_uuid or backup.get("schema_version") != 1:
                raise SafetyError("Saved network state belongs to a different instance")
            if backup.get("applied_state_sha256") != _network_state_sha256(config):
                raise SafetyError("Networking changed after activation; refusing to overwrite newer settings")
            state = backup["previous_state"]
            if state["had_network"]:
                config["Network"] = state["network"]
            else:
                config.pop("Network", None)
            if not state["had_qemu"]:
                config.pop("QEMU", None)
            elif state["had_arguments"]:
                config.setdefault("QEMU", {})["AdditionalArguments"] = state["arguments"]
            else:
                config.setdefault("QEMU", {}).pop("AdditionalArguments", None)
            mode = "restored"
        else:
            arguments = config.get("QEMU", {}).get("AdditionalArguments", [])
            networks = config.get("Network", [])
            if not isinstance(arguments, list) or any(not isinstance(arg, str) for arg in arguments):
                raise SafetyError("Invalid network command arguments")
            if not isinstance(networks, list) or len(networks) > 1 or any(not isinstance(item, dict) for item in networks):
                raise SafetyError("Custom multi-adapter configurations require manual review")
            for index, arg in enumerate(arguments[:-1]):
                if arg == "-netdev" and not re.search(r"(?:^|,)id=net0(?:,|$)", arguments[index + 1]):
                    raise SafetyError("Custom multi-adapter configurations require manual review")
            endpoint = _parse_socket_endpoint(str(kernel_socket))
            netdev = f"stream,id=net0,server=off,addr.type=unix,path={endpoint['path']}"
            if backup_path.exists():
                backup = plistlib.loads(backup_path.read_bytes())
                if backup.get("vm_uuid") != vm_uuid or backup.get("applied_state_sha256") != _network_state_sha256(config):
                    raise SafetyError("Existing network backup does not match the current settings")
                if netdev not in arguments:
                    raise SafetyError("An existing network backup targets a different endpoint")
                return {"action": "configure-network", "network_mode": "socket-vmnet",
                        "configured": True, "config_verified": True, "restored": False,
                        "changed": False, "dry_run": dry_run}
            mac = str((networks[0].get("MacAddress", "") if networks else "") or meta.get("mac_address", ""))
            if not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", mac):
                raise SafetyError("Cannot preserve the instance network adapter address")
            previous = _network_state(config)
            updated: list[str] = []
            index = 0
            while index < len(arguments):
                arg = arguments[index]
                if arg in ("-netdev", "-device") and index + 1 < len(arguments):
                    value = arguments[index + 1]
                    if arg == "-netdev" and re.search(r"(?:^|,)id=net0(?:,|$)", value):
                        index += 2
                        continue
                    if arg == "-device" and re.search(r"(?:^|,)netdev=net0(?:,|$)", value):
                        index += 2
                        continue
                updated.append(arg)
                index += 1
            updated.extend(["-netdev", netdev, "-device", f"virtio-net-pci,netdev=net0,mac={mac}"])
            _assert_safe_qemu_args(updated)
            config["Network"] = []
            config.setdefault("QEMU", {})["AdditionalArguments"] = updated
            backup = {"schema_version": 1, "vm_uuid": vm_uuid, "previous_state": previous,
                      "applied_state_sha256": _network_state_sha256(config)}
            mode = "socket-vmnet"
        if utmctl_status(vm_uuid, utmctl) != "stopped" or config_path.read_bytes() != original:
            raise SafetyError("Instance or configuration changed during network setup; retry while stopped")
        _assert_no_saved_guest_state(playable_path)
        if not dry_run:
            if not restore:
                _atomic_private_plist(backup_path, backup)
            _atomic_private_plist(config_path, config, mode=stat.S_IMODE(config_path.stat().st_mode))
            observed = read_config_plist(playable_path)
            if _network_state_sha256(observed) != _network_state_sha256(config):
                raise GoldenGuestError("Network configuration verification failed; saved state is retained")
            if restore:
                backup_path.unlink()
        return {"action": "configure-network", "network_mode": mode,
                "configured": not dry_run, "config_verified": not dry_run,
                "restored": restore and not dry_run, "changed": not dry_run, "dry_run": dry_run}


def _validate_managed_vm_bundle(
    bundle_path: Path,
    *,
    golden: Path | None = None,
    primary: Path | None = None,
) -> tuple[dict[str, Any], str]:
    """Validate that bundle_path is a managed playable or ephemeral VM (never golden or primary)."""
    assert_not_primary(bundle_path, primary)
    assert_not_golden(bundle_path, golden)
    if not bundle_path.is_dir():
        raise GoldenGuestError(f"VM bundle not found: {redact_text(str(bundle_path))}")
    for meta_name, expected_role in (
        (PLAYABLE_META_FILENAME, "playable_working_vm"),
        (EPHEMERAL_META_FILENAME, "ephemeral_golden_clone"),
    ):
        meta_path = bundle_path / meta_name
        if meta_path.is_file():
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if meta.get("role") != expected_role:
                raise SafetyError(f"Invalid VM role marker in {meta_name}; refusing operation")
            vm_uuid = str(meta.get("vm_uuid") or meta.get("clone_uuid") or bundle_uuid(bundle_path))
            return meta, vm_uuid
    raise SafetyError("Refusing to manage bundle without .playable-meta.json or .ephemeral-meta.json marker")


def qmp_send_command(qmp_socket_path: Path, execute: str, timeout: float = 10.0) -> dict[str, Any]:
    """Send a single QMP command (strictly stop/cont/query-status) over an internal Unix socket."""
    if execute not in ("stop", "cont", "query-status"):
        raise SafetyError(f"Unsupported QMP command: {execute}")
    if not qmp_socket_path.exists():
        raise GoldenGuestError(f"QMP socket not found: {redact_text(str(qmp_socket_path))}")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(qmp_socket_path))
        reader = sock.makefile("r", encoding="utf-8", errors="replace")
        _greeting = reader.readline()
        sock.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode("utf-8"))
        _caps = reader.readline()
        sock.sendall((json.dumps({"execute": execute}) + "\n").encode("utf-8"))
        for _ in range(8):
            line = reader.readline()
            if not line:
                break
            payload = json.loads(line)
            if "return" in payload or "error" in payload:
                return payload
    raise GoldenGuestError(f"QMP command '{execute}' returned no response")


def sample_qemu_standby_metrics() -> dict[str, Any]:
    """Sample QEMU worker CPU%, RSS MiB, and macOS native memory compressor pages."""
    qemu_cpu = 0.0
    qemu_rss_mib = 0.0
    worker_count = 0
    ps_res = subprocess.run(
        ["ps", "-axo", "pcpu=,rss=,comm="],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if ps_res.returncode == 0:
        for line in ps_res.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 3:
                continue
            comm = parts[2]
            if "qemu-aarch64-softmmu" in comm or "QEMUHelper" in comm:
                try:
                    qemu_cpu += float(parts[0])
                    qemu_rss_mib += float(parts[1]) / 1024.0
                    worker_count += 1
                except ValueError:
                    continue

    compressor_pages = 0
    page_size = 16384
    vm_res = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=10)
    if vm_res.returncode == 0:
        for line in vm_res.stdout.splitlines():
            m_page = re.search(r"page size of (\d+) bytes", line)
            if m_page:
                page_size = int(m_page.group(1))
            if "Pages occupied by compressor" in line:
                m_val = re.search(r":\s*(\d+)", line)
                if m_val:
                    compressor_pages = int(m_val.group(1))
    return {
        "qemu_worker_count": worker_count,
        "qemu_cpu_pct": round(qemu_cpu, 2),
        "qemu_rss_mib": round(qemu_rss_mib, 2),
        "macos_compressor_mib": round((compressor_pages * page_size) / (1024.0 * 1024.0), 2),
    }


def _wait_qga_ping(vm_uuid: str, utmctl: Path, timeout_sec: float = 90.0) -> float:
    """Wait until QEMU Guest Agent responds to a lightweight exec ping and return elapsed seconds."""
    t0 = time.monotonic()
    deadline = t0 + timeout_sec
    while time.monotonic() < deadline:
        try:
            res = subprocess.run(
                [str(utmctl), "exec", vm_uuid, "--cmd", "cmd.exe", "/c", "echo", "QGA_OK"],
                capture_output=True,
                text=True,
                timeout=12,
            )
            if res.returncode == 0 and "QGA_OK" in (res.stdout or ""):
                return round(time.monotonic() - t0, 3)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.5)
    raise GoldenGuestError(f"QGA did not respond within {timeout_sec:.1f}s")


def pause_vm(
    bundle_path: Path,
    *,
    golden: Path | None = None,
    primary: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    qmp_socket: Path | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Pause a running managed VM into 0% CPU warm-standby via QMP stop / utmctl suspend."""
    meta, vm_uuid = _validate_managed_vm_bundle(bundle_path, golden=golden, primary=primary)
    if dry_run:
        return {
            "action": "pause",
            "vm_name": meta.get("vm_name") or meta.get("clone_name"),
            "vm_uuid": vm_uuid,
            "transport": "qmp" if qmp_socket else "utmctl-suspend",
            "dry_run": True,
            "paused": False,
        }

    t0 = time.monotonic()
    transport = "utmctl-suspend"
    if qmp_socket is not None:
        transport = "qmp-stop"
        qmp_send_command(qmp_socket, "stop")
        status = "paused"
    else:
        state = utmctl_status(vm_uuid, utmctl)
        if state not in ("paused", "suspended"):
            sus_res = subprocess.run(
                [str(utmctl), "suspend", vm_uuid],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if sus_res.returncode != 0:
                raise GoldenGuestError(f"Failed to pause VM: {redact_text(sus_res.stderr)}")
            for _ in range(40):
                state = utmctl_status(vm_uuid, utmctl)
                if state in ("paused", "suspended"):
                    break
                time.sleep(0.25)
        status = state

    pause_seconds = round(time.monotonic() - t0, 3)
    time.sleep(1.0)
    metrics = sample_qemu_standby_metrics()
    return {
        "action": "pause",
        "vm_name": meta.get("vm_name") or meta.get("clone_name"),
        "vm_uuid": vm_uuid,
        "transport": transport,
        "status": status,
        "paused": status in ("paused", "suspended"),
        "pause_seconds": pause_seconds,
        "standby_metrics": metrics,
    }


def warm_standby(
    bundle_path: Path,
    *,
    golden: Path | None = None,
    primary: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    qmp_socket: Path | None = None,
    wait_qga_timeout: float = 120.0,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Boot a managed VM to QGA-ready state and immediately park it in 0% CPU warm standby."""
    meta, vm_uuid = _validate_managed_vm_bundle(bundle_path, golden=golden, primary=primary)
    if dry_run:
        return {
            "action": "warm-standby",
            "vm_name": meta.get("vm_name") or meta.get("clone_name"),
            "vm_uuid": vm_uuid,
            "dry_run": True,
            "standby_ready": False,
        }

    state = utmctl_status(vm_uuid, utmctl)
    if state == "unregistered":
        reg_res = subprocess.run(["open", "-a", "UTM", str(bundle_path)], capture_output=True, text=True, timeout=30)
        if reg_res.returncode != 0:
            raise GoldenGuestError("Failed to register VM for warm standby")
        for _ in range(20):
            state = utmctl_status(vm_uuid, utmctl)
            if state != "unregistered":
                break
            time.sleep(0.5)

    t_boot = time.monotonic()
    if state != "started":
        start_res = subprocess.run([str(utmctl), "start", vm_uuid], capture_output=True, text=True, timeout=120)
        if start_res.returncode != 0:
            raise GoldenGuestError(f"Failed to start VM for warm standby: {redact_text(start_res.stderr)}")
    qga_ready_seconds = _wait_qga_ping(vm_uuid, utmctl, timeout_sec=wait_qga_timeout)
    cold_boot_total_seconds = round(time.monotonic() - t_boot, 3)

    pause_res = pause_vm(
        bundle_path,
        golden=golden,
        primary=primary,
        utmctl=utmctl,
        qmp_socket=qmp_socket,
        dry_run=False,
    )
    return {
        "action": "warm-standby",
        "vm_name": meta.get("vm_name") or meta.get("clone_name"),
        "vm_uuid": vm_uuid,
        "cold_boot_to_qga_seconds": cold_boot_total_seconds,
        "qga_ping_seconds": qga_ready_seconds,
        "pause_seconds": pause_res["pause_seconds"],
        "status": pause_res["status"],
        "standby_ready": bool(pause_res["paused"]),
        "standby_metrics": pause_res["standby_metrics"],
    }


def resume_launch(
    bundle_path: Path,
    *,
    golden: Path | None = None,
    primary: Path | None = None,
    utmctl: Path = DEFAULT_UTMCTL,
    qmp_socket: Path | None = None,
    wait_qga_timeout: float = 90.0,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Resume a warm-standby VM via QMP cont / utmctl start, or perform streamlined cold boot."""
    meta, vm_uuid = _validate_managed_vm_bundle(bundle_path, golden=golden, primary=primary)
    if dry_run:
        return {
            "action": "resume-launch",
            "vm_name": meta.get("vm_name") or meta.get("clone_name"),
            "vm_uuid": vm_uuid,
            "dry_run": True,
            "resumed": False,
        }

    state_before = utmctl_status(vm_uuid, utmctl)
    if state_before == "unregistered":
        reg_res = subprocess.run(["open", "-a", "UTM", str(bundle_path)], capture_output=True, text=True, timeout=30)
        if reg_res.returncode != 0:
            raise GoldenGuestError("Failed to register VM for resume-launch")
        for _ in range(20):
            state_before = utmctl_status(vm_uuid, utmctl)
            if state_before != "unregistered":
                break
            time.sleep(0.5)

    launch_mode = "warm_resume" if (state_before in ("paused", "suspended") or qmp_socket is not None) else "cold_boot"
    t0 = time.monotonic()
    if qmp_socket is not None:
        qmp_send_command(qmp_socket, "cont")
    elif state_before != "started":
        start_res = subprocess.run([str(utmctl), "start", vm_uuid], capture_output=True, text=True, timeout=120)
        if start_res.returncode != 0:
            raise GoldenGuestError(f"Failed to resume/start VM: {redact_text(start_res.stderr)}")
    vm_started_seconds = round(time.monotonic() - t0, 3)
    qga_ready_seconds = _wait_qga_ping(vm_uuid, utmctl, timeout_sec=wait_qga_timeout)
    total_ready_seconds = round(time.monotonic() - t0, 3)

    return {
        "action": "resume-launch",
        "vm_name": meta.get("vm_name") or meta.get("clone_name"),
        "vm_uuid": vm_uuid,
        "state_before": state_before,
        "launch_mode": launch_mode,
        "vm_started_seconds": vm_started_seconds,
        "qga_ready_seconds": qga_ready_seconds,
        "total_ready_seconds": total_ready_seconds,
        "status": utmctl_status(vm_uuid, utmctl),
        "resumed": True,
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

    sub.add_parser("check-network", help="Read-only probe of host vmnet and socket_vmnet capabilities")

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
    p_spawn.add_argument("--trim-hardware", action="store_true", help="Trim unused USB/CD-ROM slots and lock DynamicResolution=false (preserves sound unless --no-sound)")
    p_spawn.add_argument("--no-sound", action="store_true", help="Explicitly strip virtual sound device (for headless benchmarks)")
    p_spawn.add_argument("--sound-hardware", choices=SUPPORTED_SOUND_HARDWARES, default=None, help="Audio hardware (default: intel-hda; optional virtio-sound-pci evaluation)")
    p_spawn.add_argument(
        "--dx-driver",
        choices=tuple(SUPPORTED_DX_DRIVERS.keys()),
        default=None,
        help="Optional native Neptune DirectX driver enum override (D3DMetal=0, DXMT=2)",
    )
    p_spawn.add_argument("--fps-limit", type=int, default=None, help="Optional QEMURendererFPSLimit override")
    p_spawn.add_argument("--ram-mb", type=int, choices=ALLOWED_RAM_MB, default=None, help="Guest RAM allocation in MiB")
    p_spawn.add_argument("--vcpu", type=int, default=None, help="Guest vCPU count (match Apple Silicon P-Core count)")
    p_spawn.add_argument("--disable-balloon", action="store_true", help="Disable VirtIO Memory Balloon device")
    p_spawn.add_argument("--pure-relative-mouse", action="store_true", help="Set PureRelativeMouse=true for custom UTM 11B")
    p_spawn.add_argument("--virtio-mouse", action="store_true", help="Use WHQL virtio-mouse-pci instead of emulated usb-mouse (Secure Boot preserved)")
    p_spawn.add_argument("--keep-usb-redir", action="store_true", help="Keep usb-redir channels instead of stripping unused redirection devices")
    p_spawn.add_argument("--no-iosurface-direct", action="store_true", help="Disable IOSurface direct present metadata flag")
    p_spawn.add_argument(
        "--network-mode",
        choices=SUPPORTED_NETWORK_MODES,
        default=None,
        help="Network backend: vmnet-shared (native kernel), socket-vmnet, socket-stream, or emulated (slirp)",
    )
    p_spawn.add_argument("--socket-endpoint", type=str, default=None, help="host:port or /path/to/socket for socket-vmnet/socket-stream")
    p_spawn.add_argument("--net-rx-queue-size", type=int, choices=ALLOWED_NET_RX_QUEUE_SIZES, default=None)
    p_spawn.add_argument("--disk-interface", choices=SUPPORTED_DISK_INTERFACES, default=None, help="Disk interface: virtio or nvme")
    p_spawn.add_argument("--iothread", action="store_true", help="Enable dedicated QEMU iothread for VirtIO-Blk disks")
    p_spawn.add_argument("--io-queues", type=int, default=None, help="VirtIO-Blk num-queues (1..8, default 4 with --iothread)")

    p_create_play = sub.add_parser("create-playable", help="Create or reset persistent daily-playable APFS CoW VM")
    p_create_play.add_argument("--golden", type=Path, required=True)
    p_create_play.add_argument("--dest-dir", type=Path, default=None)
    p_create_play.add_argument("--name", type=str, default="playable-win11-arm64")
    p_create_play.add_argument("--primary", type=Path, default=None)
    p_create_play.add_argument("--reset", action="store_true", help="Reset existing playable VM back to sealed golden image")
    p_create_play.add_argument("--register-utm", action="store_true")
    p_create_play.add_argument("--fast-disk-hash", action="store_true")
    p_create_play.add_argument("--no-sound", action="store_true", help="Explicitly strip virtual sound device")
    p_create_play.add_argument("--sound-hardware", choices=SUPPORTED_SOUND_HARDWARES, default=None, help="Audio hardware (default: intel-hda; optional virtio-sound-pci evaluation)")
    p_create_play.add_argument(
        "--dx-driver",
        choices=tuple(SUPPORTED_DX_DRIVERS.keys()),
        default="DXMT",
        help="Native DirectX driver override (default: DXMT)",
    )
    p_create_play.add_argument("--fps-limit", type=int, default=DEFAULT_RENDERER_FPS_LIMIT)
    p_create_play.add_argument("--ram-mb", type=int, choices=ALLOWED_RAM_MB, default=DEFAULT_PLAYABLE_RAM_MB)
    p_create_play.add_argument("--vcpu", type=int, default=None, help="Guest vCPU count (defaults to benchmarked Apple Silicon recommendation)")
    p_create_play.add_argument("--keep-balloon", action="store_true", help="Keep VirtIO Memory Balloon enabled (disabled by default for playable VM)")
    p_create_play.add_argument("--pure-relative-mouse", action="store_true", default=True, help="Set PureRelativeMouse=true (default: enabled)")
    p_create_play.add_argument("--usb-mouse-fallback", action="store_true", help="Fallback to emulated usb-mouse instead of default WHQL virtio-mouse-pci")
    p_create_play.add_argument("--keep-usb-redir", action="store_true", help="Keep usb-redir channels (stripped by default in Phase 15A)")
    p_create_play.add_argument("--no-iosurface-direct", action="store_true", help="Disable IOSurface direct present default")
    p_create_play.add_argument(
        "--network-mode",
        choices=SUPPORTED_NETWORK_MODES,
        default=DEFAULT_PLAYABLE_NETWORK_MODE,
        help="Network backend (default: vmnet-shared; use socket-vmnet or socket-stream for ad-hoc UTM-Custom)",
    )
    p_create_play.add_argument("--socket-endpoint", type=str, default=None, help="host:port or /path/to/socket for socket-vmnet/socket-stream")
    p_create_play.add_argument("--net-rx-queue-size", type=int, choices=ALLOWED_NET_RX_QUEUE_SIZES, default=DEFAULT_NET_RX_QUEUE_SIZE)
    p_create_play.add_argument("--disk-interface", choices=SUPPORTED_DISK_INTERFACES, default=DEFAULT_PLAYABLE_DISK_INTERFACE)
    p_create_play.add_argument("--no-iothread", action="store_true", help="Disable dedicated VirtIO-Blk iothread (enabled by default)")
    p_create_play.add_argument("--io-queues", type=int, default=DEFAULT_IO_QUEUES, help="VirtIO-Blk num-queues (default: 4)")

    p_import = sub.add_parser("import-playable", help="Import an explicitly selected, completely stopped working instance")
    p_import.add_argument("--playable", type=Path, required=True)
    p_import.add_argument("--confirmed-stopped", action="store_true")
    p_import.add_argument("--golden", type=Path, default=None)
    p_import.add_argument("--primary", type=Path, default=None)
    p_import.add_argument("--dry-run", action="store_true")

    p_network = sub.add_parser("configure-network", help="Apply or restore native networking on a stopped playable instance")
    p_network.add_argument("--playable", type=Path, required=True)
    p_network.add_argument("--utmctl", type=Path, default=DEFAULT_UTMCTL)
    p_network.add_argument("--golden", type=Path, default=None)
    p_network.add_argument("--primary", type=Path, default=None)
    p_network.add_argument("--restore", action="store_true")
    p_network.add_argument("--dry-run", action="store_true")

    p_launch_play = sub.add_parser("launch-playable", help="Register (if needed) and launch persistent playable VM")
    p_launch_play.add_argument("--playable", type=Path, required=True)
    p_launch_play.add_argument("--golden", type=Path, default=None)
    p_launch_play.add_argument("--primary", type=Path, default=None)
    p_launch_play.add_argument("--dry-run", action="store_true")

    p_warm = sub.add_parser("warm-standby", help="Boot VM to ready state and pause into 0%% CPU warm standby")
    p_warm.add_argument("--playable", type=Path, required=True)
    p_warm.add_argument("--golden", type=Path, default=None)
    p_warm.add_argument("--primary", type=Path, default=None)
    p_warm.add_argument("--qmp-socket", type=Path, default=None)
    p_warm.add_argument("--wait-qga-timeout", type=float, default=120.0)
    p_warm.add_argument("--dry-run", action="store_true")

    p_pause = sub.add_parser("pause", help="Pause running managed VM via QMP stop / utmctl suspend")
    p_pause.add_argument("--playable", type=Path, required=True)
    p_pause.add_argument("--golden", type=Path, default=None)
    p_pause.add_argument("--primary", type=Path, default=None)
    p_pause.add_argument("--qmp-socket", type=Path, default=None)
    p_pause.add_argument("--dry-run", action="store_true")

    p_resume = sub.add_parser("resume-launch", help="Fast-resume warm-standby VM or streamlined cold boot")
    p_resume.add_argument("--playable", type=Path, required=True)
    p_resume.add_argument("--golden", type=Path, default=None)
    p_resume.add_argument("--primary", type=Path, default=None)
    p_resume.add_argument("--qmp-socket", type=Path, default=None)
    p_resume.add_argument("--wait-qga-timeout", type=float, default=90.0)
    p_resume.add_argument("--dry-run", action="store_true")

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
    elif args.command == "check-network":
        result = detect_host_network_capabilities()
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
            trim_hardware=args.trim_hardware,
            no_sound=args.no_sound,
            sound_hardware=args.sound_hardware,
            dx_driver=args.dx_driver,
            fps_limit=args.fps_limit,
            ram_mb=args.ram_mb,
            vcpu=args.vcpu,
            disable_balloon=args.disable_balloon,
            pure_relative_mouse=args.pure_relative_mouse,
            virtio_mouse=args.virtio_mouse,
            disable_usb_redir=False if args.keep_usb_redir else None,
            iosurface_direct_present=False if args.no_iosurface_direct else None,
            network_mode=args.network_mode,
            socket_endpoint=args.socket_endpoint,
            net_rx_queue_size=args.net_rx_queue_size,
            disk_interface=args.disk_interface,
            enable_iothread=args.iothread,
            io_queues=args.io_queues,
        )
    elif args.command == "create-playable":
        result = create_playable(
            golden=args.golden,
            dest_dir=args.dest_dir,
            name=args.name,
            primary=args.primary,
            reset=args.reset,
            register_utm=args.register_utm,
            fast_disk_hash=args.fast_disk_hash,
            trim_hardware=True,
            no_sound=args.no_sound,
            sound_hardware=args.sound_hardware,
            dx_driver=args.dx_driver,
            fps_limit=args.fps_limit,
            ram_mb=args.ram_mb,
            vcpu=args.vcpu,
            disable_balloon=not args.keep_balloon,
            pure_relative_mouse=args.pure_relative_mouse,
            virtio_mouse=not args.usb_mouse_fallback,
            disable_usb_redir=not args.keep_usb_redir,
            iosurface_direct_present=not args.no_iosurface_direct,
            network_mode=args.network_mode,
            socket_endpoint=args.socket_endpoint,
            net_rx_queue_size=args.net_rx_queue_size,
            disk_interface=args.disk_interface,
            enable_iothread=not args.no_iothread,
            io_queues=args.io_queues,
        )
    elif args.command == "import-playable":
        try:
            result = import_playable(args.playable, confirmed_stopped=args.confirmed_stopped,
                                     golden=args.golden, primary=args.primary, dry_run=args.dry_run)
        except PlayableImportError as error:
            print(json.dumps({"action": "import-playable", "imported": False,
                              "error_code": error.code, "message": str(error)}, ensure_ascii=False))
            return 1
        except (OSError, ValueError, UnicodeError, plistlib.InvalidFileException, ExpatError):
            print(json.dumps({"action": "import-playable", "imported": False,
                              "error_code": "invalid_configuration",
                              "message": "Import could not safely verify this instance"}))
            return 1
    elif args.command == "configure-network":
        try:
            result = configure_playable_network(
                playable_path=args.playable, restore=args.restore, utmctl=args.utmctl,
                golden=args.golden, primary=args.primary, dry_run=args.dry_run,
            )
        except (GoldenGuestError, OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
            print(json.dumps({"action": "configure-network", "configured": False,
                              "config_verified": False, "message": redact_text(str(error))}, ensure_ascii=False))
            return 1
    elif args.command == "launch-playable":
        result = launch_playable(
            playable_path=args.playable,
            golden=args.golden,
            primary=args.primary,
            dry_run=args.dry_run,
        )
    elif args.command == "warm-standby":
        result = warm_standby(
            bundle_path=args.playable,
            golden=args.golden,
            primary=args.primary,
            qmp_socket=args.qmp_socket,
            wait_qga_timeout=args.wait_qga_timeout,
            dry_run=args.dry_run,
        )
    elif args.command == "pause":
        result = pause_vm(
            bundle_path=args.playable,
            golden=args.golden,
            primary=args.primary,
            qmp_socket=args.qmp_socket,
            dry_run=args.dry_run,
        )
    elif args.command == "resume-launch":
        result = resume_launch(
            bundle_path=args.playable,
            golden=args.golden,
            primary=args.primary,
            qmp_socket=args.qmp_socket,
            wait_qga_timeout=args.wait_qga_timeout,
            dry_run=args.dry_run,
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

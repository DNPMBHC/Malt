#!/usr/bin/env python3
"""Host-side validator and isolated-clone benchmark runner for Phase 3-A / 4C Guest optimizer.

Owner: @DNPMBHC
Safety guarantee: Refuses to operate on the primary clean vm-a UUID. Only executes against an
explicitly separate cloned VM snapshot on the external volume.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_DIR = SCRIPT_DIR.parent
WORKSPACE_ROOT = MODULE_DIR.parents[2]
DEFAULT_PROFILE = MODULE_DIR / "profiles" / "anticheat-minimal-win11-arm64.json"
DEFAULT_APPLY_SCRIPT = SCRIPT_DIR / "apply-optimizer.ps1"
DEFAULT_ROLLBACK_SCRIPT = SCRIPT_DIR / "rollback-optimizer.ps1"
DEFAULT_EVIDENCE_DIR = WORKSPACE_ROOT / "handoff" / "phase-4" / "evidence" / "p4-c"
GUEST_OPT_DIR = r"C:\graphics-lab\guest-optimizer"

HARD_PROTECTED_SERVICES = frozenset({
    "bfe", "coremessagingregistrar", "cryptsvc", "dcomlaunch", "dhcp", "dnscache",
    "eventlog", "keyiso", "lsm", "mpssvc", "netman", "nlasvc", "nsi", "plugplay",
    "power", "qemu-ga", "rpceptmapper", "rpcss", "samss", "schedule",
    "securityhealthservice", "sense", "systemeventsbroker", "tbs",
    "trustedinstaller", "usermanager", "vaultsvc", "virtiofssvc", "windefend",
    "winmgmt", "audiosrv", "audioendpointbuilder", "wuauserv",
    "vgc", "vgk", "ace-base", "ace-game", "ace-core10405", "ace-core20405",
    "anticheatexpert", "anticheatexpert service",
    "anticheatexpert protection", "easyanticheat", "easyanticheat_eos",
    "easyanticheat_eossys", "beservice",
})

ALLOWED_UPDATE_PAUSE_SERVICES = frozenset({
    "wuauserv", "usosvc", "bits", "trustedinstaller",
})

HARD_PROTECTED_APPX_PREFIXES = (
    "microsoft.vclibs", "microsoft.ui.xaml", "microsoft.net", "microsoft.directx",
    "microsoft.windows.shellexperiencehost", "microsoft.windows.startmenuexperiencehost",
    "microsoft.windows.sechealthui", "microsoft.aad.brokerplugin",
    "microsoft.accountscontrol", "microsoft.lockapp", "microsoft.desktopappinstaller",
    "microsoft.services.store.engagement", "microsoft.storepurchaseapp",
    "microsoft.windowsstore",
)

HARD_PROTECTED_TASK_PREFIXES = (
    "\\microsoft\\windows\\windows defender\\",
    "\\microsoft\\windows\\tpm\\",
    "\\microsoft\\windows\\device information\\",
    "\\microsoft\\windows\\certificateservicesclient\\",
    "\\microsoft\\windows\\servicing\\",
    "\\microsoft\\windows\\taskscheduler\\",
)

REQUIRED_PRISM_FILES = frozenset({
    "system32\\xtajit.dll",
    "system32\\xtajit64.dll",
    "system32\\wow64.dll",
    "system32\\wow64win.dll",
})

REQUIRED_COMPLIANCE_FLAGS = (
    "forbid_virtualization_hiding",
    "forbid_hardware_spoofing",
    "forbid_bcd_or_ci_weakening",
    "forbid_kernel_driver_tampering",
    "preserve_official_signatures",
)

FORBIDDEN_REGISTRY_FRAGMENTS = re.compile(
    r"(?:deviceguard|codeintegrity|lsa|policies\\system|currentcontrolset)",
    re.IGNORECASE,
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(text: str) -> str:
    redacted = str(text)
    redacted = redacted.replace(str(WORKSPACE_ROOT), "<workspace>")
    redacted = redacted.replace(str(Path.home()), "<home>")
    for token in (WORKSPACE_ROOT.name, os.environ.get("USER", ""), platform.node()):
        if token:
            redacted = redacted.replace(token, "<private-id>")
    redacted = re.sub(
        r"/Volumes/[^/\s\"'<>`]+",
        "/Volumes/<EXTERNAL_VOLUME>",
        redacted,
    )
    redacted = re.sub(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
        "vm-clone",
        redacted,
    )
    redacted = re.sub(
        r"(?<![\w.])/(?:Users|private|tmp)/[^\s\"'<>`]+",
        "<path>",
        redacted,
    )
    return redacted


def clean_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): clean_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean_value(v) for v in value]
    return redact_text(value) if isinstance(value, str) else value


def validate_profile(profile: dict[str, Any]) -> None:
    if not isinstance(profile, dict):
        raise ValueError("optimizer profile must be a JSON object")
    if profile.get("schema_version") != 1:
        raise ValueError("optimizer profile schema_version must be 1")
    if not isinstance(profile.get("profile_id"), str) or not profile["profile_id"].strip():
        raise ValueError("optimizer profile_id must be a non-empty string")
    if profile.get("owner") != "@DNPMBHC":
        raise ValueError("optimizer profile owner must be @DNPMBHC")

    target_os = profile.get("target_os")
    if not isinstance(target_os, dict):
        raise ValueError("target_os must be an object")
    if target_os.get("architecture") != "ARM64" or target_os.get("display_version") != "24H2":
        raise ValueError("target_os must target Windows 11 24H2 ARM64")
    if type(target_os.get("minimum_build")) is not int or target_os["minimum_build"] < 26100:
        raise ValueError("target_os minimum_build must be >= 26100")

    compliance = profile.get("compliance")
    if not isinstance(compliance, dict):
        raise ValueError("compliance section is required")
    for flag in REQUIRED_COMPLIANCE_FLAGS:
        if compliance.get(flag) is not True:
            raise ValueError(f"compliance flag '{flag}' must be true")

    whitelist = profile.get("protected_whitelist")
    blacklist = profile.get("optimization_blacklist")
    if not isinstance(whitelist, dict) or not isinstance(blacklist, dict):
        raise ValueError("protected_whitelist and optimization_blacklist must be objects")

    wl_services = {str(s).lower() for s in whitelist.get("services", [])}
    if not HARD_PROTECTED_SERVICES.issubset(wl_services):
        missing = sorted(HARD_PROTECTED_SERVICES - wl_services)
        raise ValueError(f"protected_whitelist.services missing required core services: {missing[:5]}")
    effective_protected_services = HARD_PROTECTED_SERVICES | wl_services

    wl_prism = {str(p).lower() for p in whitelist.get("prism_files", [])}
    if not REQUIRED_PRISM_FILES.issubset(wl_prism):
        raise ValueError("protected_whitelist.prism_files must cover Prism AVX2 and WOW64 binaries")

    effective_protected_appx = tuple(
        dict.fromkeys(
            list(HARD_PROTECTED_APPX_PREFIXES)
            + [str(p).lower() for p in whitelist.get("appx_prefixes", [])]
        )
    )
    effective_protected_tasks = tuple(
        dict.fromkeys(
            list(HARD_PROTECTED_TASK_PREFIXES)
            + [str(p).lower() for p in whitelist.get("task_prefixes", [])]
        )
    )

    seen_services: set[str] = set()
    for entry in blacklist.get("services", []):
        if not isinstance(entry, dict):
            raise ValueError("blacklist service entry must be an object")
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("blacklist service name must be a non-empty string")
        lowered = name.lower()
        if lowered in effective_protected_services:
            raise ValueError(f"whitelist violation: protected service '{name}' in blacklist")
        if lowered in seen_services:
            raise ValueError(f"duplicate blacklist service '{name}'")
        seen_services.add(lowered)
        if entry.get("target_start_type") not in ("Disabled", "Manual"):
            raise ValueError(f"invalid target_start_type for service '{name}'")
        if type(entry.get("stop_running")) is not bool:
            raise ValueError(f"stop_running must be boolean for service '{name}'")

    for pkg in blacklist.get("uwp_packages", []):
        if not isinstance(pkg, str) or not pkg.strip():
            raise ValueError("blacklist uwp_packages entries must be non-empty strings")
        lowered = pkg.lower()
        if any(lowered.startswith(prefix) for prefix in effective_protected_appx):
            raise ValueError(f"whitelist violation: protected UWP package '{pkg}' in blacklist")

    for entry in blacklist.get("scheduled_tasks", []):
        if not isinstance(entry, dict):
            raise ValueError("blacklist scheduled_tasks entry must be an object")
        task_path = entry.get("task_path")
        task_name = entry.get("task_name")
        if not isinstance(task_path, str) or not isinstance(task_name, str) or not task_name.strip():
            raise ValueError("scheduled_tasks entry requires string task_path and task_name")
        full = (task_path + task_name).lower()
        if any(full.startswith(prefix) for prefix in effective_protected_tasks):
            raise ValueError(f"whitelist violation: protected task '{task_path}{task_name}' in blacklist")

    for entry in blacklist.get("registry_tweaks", []):
        if not isinstance(entry, dict):
            raise ValueError("blacklist registry_tweaks entry must be an object")
        path = entry.get("path")
        name = entry.get("name")
        kind = entry.get("kind")
        if not isinstance(path, str) or not isinstance(name, str) or not name.strip():
            raise ValueError("registry_tweaks entry requires string path and name")
        if not path.lower().startswith("hkcu:\\"):
            raise ValueError(f"whitelist violation: registry path '{path}' must be scoped to HKCU:\\")
        if FORBIDDEN_REGISTRY_FRAGMENTS.search(path):
            raise ValueError(f"whitelist violation: forbidden security registry path '{path}'")
        if kind not in ("DWord", "String", "QWord"):
            raise ValueError(f"unsupported registry kind '{kind}'")

    gaming_controls = profile.get("gaming_session_controls")
    if gaming_controls is not None:
        if not isinstance(gaming_controls, dict):
            raise ValueError("gaming_session_controls must be an object")

        locale_cfg = gaming_controls.get("locale_and_ime")
        if locale_cfg is not None:
            if not isinstance(locale_cfg, dict) or type(locale_cfg.get("enabled")) is not bool:
                raise ValueError("gaming_session_controls.locale_and_ime requires boolean enabled")
            langs = locale_cfg.get("preferred_languages", [])
            if not isinstance(langs, list) or not all(isinstance(x, str) and x.strip() for x in langs):
                raise ValueError("locale_and_ime.preferred_languages must be a list of non-empty strings")

        seen_pause: set[str] = set()
        for entry in gaming_controls.get("update_pause_services", []):
            if not isinstance(entry, dict):
                raise ValueError("update_pause_services entry must be an object")
            name = entry.get("name")
            if not isinstance(name, str) or not name.strip():
                raise ValueError("update_pause_services service name must be a non-empty string")
            lowered = name.lower()
            if lowered not in ALLOWED_UPDATE_PAUSE_SERVICES:
                raise ValueError(f"whitelist violation: '{name}' is not allowed in update_pause_services")
            if lowered in seen_pause:
                raise ValueError(f"duplicate update_pause_services entry '{name}'")
            seen_pause.add(lowered)
            if entry.get("target_start_type") != "Manual":
                raise ValueError(f"update_pause_services '{name}' must use target_start_type='Manual'")
            if type(entry.get("stop_running")) is not bool:
                raise ValueError(f"update_pause_services '{name}' stop_running must be boolean")

        pagefile = gaming_controls.get("pagefile")
        if pagefile is not None:
            if not isinstance(pagefile, dict) or type(pagefile.get("enabled")) is not bool:
                raise ValueError("gaming_session_controls.pagefile requires boolean enabled")
            init_mb = pagefile.get("initial_size_mb")
            max_mb = pagefile.get("maximum_size_mb")
            if type(init_mb) is not int or type(max_mb) is not int:
                raise ValueError("pagefile sizes must be integers")
            if init_mb < 4096 or max_mb < init_mb or max_mb > 32768:
                raise ValueError("pagefile size out of safe bounds (4096 <= initial <= maximum <= 32768)")

        cpu_mem = gaming_controls.get("cpu_and_memory_tuning")
        if cpu_mem is not None:
            if not isinstance(cpu_mem, dict):
                raise ValueError("cpu_and_memory_tuning must be an object")
            if cpu_mem.get("power_plan") not in ("HighPerformance", "Balanced"):
                raise ValueError("cpu_and_memory_tuning.power_plan must be HighPerformance or Balanced")
            prio = cpu_mem.get("win32_priority_separation")
            if type(prio) is not int or prio < 0 or prio > 0x3F:
                raise ValueError("win32_priority_separation must be an integer in 0..63")
            if cpu_mem.get("memory_compression") not in ("preserve", "disable"):
                raise ValueError("memory_compression must be 'preserve' or 'disable'")


def assert_clone_vm_safe(target_vm_id: str, primary_vm_id: str) -> None:
    uuid_pattern = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
    if not uuid_pattern.match(target_vm_id) or not uuid_pattern.match(primary_vm_id):
        raise ValueError("VM identifiers must be valid UUIDs")
    if target_vm_id.lower() == primary_vm_id.lower():
        raise ValueError("refusing to run optimizer benchmark against primary clean vm-a")


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def discover_utmctl() -> Path:
    found = shutil.which("utmctl")
    if found:
        return Path(found)
    candidate = Path("/Applications/UTM.app/Contents/MacOS/utmctl")
    if not candidate.is_file():
        raise RuntimeError("utmctl utility not found")
    return candidate


def run_cmd(cmd: list[str], timeout: float = 120) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {redact_text(result.stderr[-500:])}")
    return result


def guest_powershell(utmctl: Path, vm_id: str, script: str, timeout: float = 120) -> str:
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return run_cmd(
        [str(utmctl), "exec", vm_id, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand", encoded],
        timeout=timeout,
    ).stdout.strip()


def guest_push(utmctl: Path, vm_id: str, local_path: Path, guest_path: str) -> None:
    data = local_path.read_bytes()
    result = subprocess.run(
        [str(utmctl), "file", "push", vm_id, guest_path],
        input=data,
        capture_output=True,
        check=False,
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(f"failed to push {local_path.name} to cloned Guest")


def guest_pull_text(utmctl: Path, vm_id: str, guest_path: str) -> str:
    result = subprocess.run(
        [str(utmctl), "file", "pull", vm_id, guest_path],
        capture_output=True,
        check=False,
        timeout=120,
    )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError(f"failed to pull {Path(guest_path).name} from cloned Guest")
    return result.stdout.decode("utf-8-sig", errors="replace")


def wait_vm_status(utmctl: Path, vm_id: str, wanted: str, timeout: float = 90) -> float:
    start = time.perf_counter()
    deadline = start + timeout
    while time.perf_counter() < deadline:
        status = run_cmd([str(utmctl), "status", vm_id]).stdout.strip().lower()
        if status == wanted.lower():
            return time.perf_counter() - start
        time.sleep(0.5)
    raise RuntimeError(f"VM did not reach status '{wanted}' within {timeout}s")


def wait_qga_and_desktop(utmctl: Path, vm_id: str, timeout: float = 120) -> tuple[float, float]:
    start = time.perf_counter()
    qga_ready_s: float | None = None
    deadline = start + timeout
    while time.perf_counter() < deadline:
        probe = subprocess.run(
            [str(utmctl), "exec", vm_id, "--cmd", "cmd.exe", "/d", "/c", "exit", "0"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        if probe.returncode == 0:
            if qga_ready_s is None:
                qga_ready_s = time.perf_counter() - start
            try:
                user = guest_powershell(
                    utmctl,
                    vm_id,
                    "(Get-CimInstance Win32_ComputerSystem).UserName",
                    timeout=20,
                )
                if user.strip():
                    return qga_ready_s, time.perf_counter() - start
            except Exception:
                pass
        time.sleep(1.0)
    raise RuntimeError("cloned Guest QGA or interactive desktop did not become ready in time")


def sample_host_rss_and_cpu(samples: int = 5, interval_s: float = 2.0) -> dict[str, Any]:
    utm_rss_mib: list[float] = []
    qemu_rss_mib: list[float] = []
    qemu_cpu_pct: list[float] = []
    utm_cpu_pct: list[float] = []
    for index in range(samples):
        out = run_cmd(["ps", "-axo", "pid=,rss=,%cpu=,comm="]).stdout
        u_rss = 0.0
        q_rss = 0.0
        u_cpu = 0.0
        q_cpu = 0.0
        for line in out.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) < 4:
                continue
            rss_kb = float(parts[1])
            cpu_val = float(parts[2])
            comm = parts[3]
            if comm.endswith("/UTM") or comm == "UTM":
                u_rss += rss_kb / 1024.0
                u_cpu += cpu_val
            elif "QEMULauncher" in comm or "qemu-aarch64-softmmu" in comm:
                q_rss += rss_kb / 1024.0
                q_cpu += cpu_val
        utm_rss_mib.append(u_rss)
        qemu_rss_mib.append(q_rss)
        utm_cpu_pct.append(u_cpu)
        qemu_cpu_pct.append(q_cpu)
        if index + 1 < samples:
            time.sleep(interval_s)
    return {
        "samples": samples,
        "interval_seconds": interval_s,
        "utm_rss_mib_mean": round(statistics.fmean(utm_rss_mib), 2),
        "qemu_rss_mib_mean": round(statistics.fmean(qemu_rss_mib), 2),
        "total_host_rss_mib_mean": round(
            statistics.fmean(u + q for u, q in zip(utm_rss_mib, qemu_rss_mib)), 2
        ),
        "utm_cpu_percent_mean": round(statistics.fmean(utm_cpu_pct), 2),
        "qemu_cpu_percent_mean": round(statistics.fmean(qemu_cpu_pct), 2),
    }


def measure_bundle_gib(bundle_path: Path) -> float:
    out = run_cmd(["du", "-sk", str(bundle_path)]).stdout.strip()
    kb = int(out.split()[0])
    return round(kb / (1024.0 * 1024.0), 3)


def run_interactive_script(
    utmctl: Path,
    vm_id: str,
    stem: str,
    script_guest_path: str,
    profile_guest_path: str,
    timeout: float = 300,
) -> dict[str, Any]:
    token = secrets.token_hex(6)
    task_name = f"module-4c-{stem}-{token}"
    out_file = f"{GUEST_OPT_DIR}\\{stem}-{token}.json"
    err_file = f"{GUEST_OPT_DIR}\\{stem}-{token}.err.txt"
    done_file = f"{GUEST_OPT_DIR}\\{stem}-{token}.done"
    wrapper_file = f"{GUEST_OPT_DIR}\\{stem}-{token}.ps1"

    newline_join = '"`n"'
    wrapper_code = (
        "$ErrorActionPreference='Stop'; "
        f"try {{ $res = & {ps_quote(script_guest_path)} -ProfilePath {ps_quote(profile_guest_path)} "
        f"-StateDirectory {ps_quote(GUEST_OPT_DIR)}; "
        f"[IO.File]::WriteAllText({ps_quote(out_file)}, ($res -join {newline_join}), [Text.UTF8Encoding]::new($false)); "
        f"Set-Content -Encoding ASCII -LiteralPath {ps_quote(done_file)} -Value '0' "
        f"}} catch {{ $_ | Out-String | Set-Content -Encoding UTF8 -LiteralPath {ps_quote(err_file)}; "
        f"Set-Content -Encoding ASCII -LiteralPath {ps_quote(done_file)} -Value '1' }}"
    )
    wrapper_b64 = base64.b64encode(wrapper_code.encode("utf-8")).decode("ascii")
    task_arg = '-NoProfile -ExecutionPolicy Bypass -File "' + wrapper_file + '"'
    launch = (
        "$ErrorActionPreference='Stop'; "
        "$user=(Get-CimInstance Win32_ComputerSystem).UserName; "
        "if(!$user){throw 'interactive user required'}; "
        f"New-Item -ItemType Directory -Force -Path {ps_quote(GUEST_OPT_DIR)} | Out-Null; "
        f"[IO.File]::WriteAllBytes({ps_quote(wrapper_file)}, [Convert]::FromBase64String({ps_quote(wrapper_b64)})); "
        f"$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument {ps_quote(task_arg)}; "
        "$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest; "
        f"Register-ScheduledTask -TaskName {ps_quote(task_name)} -Action $action -Principal $principal -Force | Out-Null; "
        f"Start-ScheduledTask -TaskName {ps_quote(task_name)}; 'started'"
    )
    cleanup = (
        f"Stop-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue; "
        f"Unregister-ScheduledTask -TaskName {ps_quote(task_name)} -Confirm:$false -ErrorAction SilentlyContinue; "
        f"Remove-Item -LiteralPath @({ps_quote(wrapper_file)},{ps_quote(done_file)},{ps_quote(err_file)}) -ErrorAction SilentlyContinue"
    )
    try:
        guest_powershell(utmctl, vm_id, launch, timeout=60)
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            state = guest_powershell(
                utmctl,
                vm_id,
                f"if(Test-Path {ps_quote(done_file)}){{(Get-Content {ps_quote(done_file)}).Trim()}}else{{'pending'}}",
                timeout=30,
            )
            if state == "0":
                raw = guest_pull_text(utmctl, vm_id, out_file)
                return json.loads(raw.strip())
            if state not in ("pending", ""):
                err_text = ""
                try:
                    err_text = redact_text(guest_pull_text(utmctl, vm_id, err_file))
                except Exception:
                    pass
                raise RuntimeError(f"interactive script {stem} failed: {err_text}")
            time.sleep(1.0)
        raise RuntimeError(f"interactive script {stem} timed out")
    finally:
        try:
            guest_powershell(utmctl, vm_id, cleanup, timeout=30)
        except Exception:
            pass


def collect_guest_state_snapshot(utmctl: Path, vm_id: str, run_sfc: bool = True) -> dict[str, Any]:
    sfc_clause = (
        "$sfcOut = Join-Path $env:TEMP ('sfc-' + [guid]::NewGuid().ToString('N') + '.log'); "
        "$sfcErr = Join-Path $env:TEMP ('sfc-' + [guid]::NewGuid().ToString('N') + '.err'); "
        "$sfcProc = Start-Process -FilePath 'sfc.exe' -ArgumentList '/verifyonly' "
        "-RedirectStandardOutput $sfcOut -RedirectStandardError $sfcErr -PassThru -Wait; "
        "$sfcCode = [int]$sfcProc.ExitCode; "
        "Remove-Item -LiteralPath @($sfcOut,$sfcErr) -ErrorAction SilentlyContinue; "
        if run_sfc
        else "$sfcCode = $null; "
    )
    ps = (
        "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "
        "$procs = @(Get-Process); "
        "$svcs = @(Get-Service | Where-Object { $_.Status -eq 'Running' }); "
        "$drive = Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$($env:SystemDrive)'\"; "
        "$sb = $false; try { $sb = [bool](Confirm-SecureBootUEFI) } catch {}; "
        "$tpm = Get-CimInstance -Namespace 'root\\CIMV2\\Security\\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue; "
        "$prismPaths = @('System32\\xtajit.dll','System32\\xtajit64.dll','System32\\wow64.dll','System32\\wow64win.dll'); "
        "$prismOk = $true; "
        "foreach($rel in $prismPaths){ $f=Join-Path $env:SystemRoot $rel; if(-not(Test-Path $f) -or (Get-AuthenticodeSignature $f).Status -ne 'Valid'){ $prismOk=$false } }; "
        "$bcd = @(& bcdedit.exe /enum '{current}' 2>$null); "
        "$bcdSafe = ($LASTEXITCODE -eq 0 -and @($bcd | Where-Object { $_ -match '^\\s*(testsigning|nointegritychecks)\\s+(yes|on|true|1|enabled)\\s*$' }).Count -eq 0); "
        + sfc_clause
        + "@{process_count=$procs.Count; running_service_count=$svcs.Count; "
        "system_drive_used_gib=[math]::Round(($drive.Size - $drive.FreeSpace)/1GB, 3); "
        "system_drive_free_gib=[math]::Round($drive.FreeSpace/1GB, 3); "
        "secure_boot_enabled=$sb; tpm_enabled=($null -ne $tpm -and [bool]$tpm.IsEnabled_InitialValue); "
        "bcd_safe=$bcdSafe; prism_signed_ok=$prismOk; sfc_verifyonly_exit_code=$sfcCode} | ConvertTo-Json -Compress"
    )
    for attempt in range(3):
        raw = guest_powershell(utmctl, vm_id, ps, timeout=300)
        try:
            parsed = json.loads(raw.lstrip("\ufeff"))
            if isinstance(parsed, dict) and "process_count" in parsed:
                return parsed
        except json.JSONDecodeError:
            pass
        if attempt == 2:
            raise RuntimeError("failed to read valid Guest state JSON")
        time.sleep(1.0)
    raise RuntimeError("unreachable")


def graceful_stop_vm(utmctl: Path, vm_id: str, timeout: float = 90) -> None:
    status = run_cmd([str(utmctl), "status", vm_id]).stdout.strip().lower()
    if status == "stopped":
        return
    # Issue clean Windows shutdown via QGA so NTFS/registry hives flush and WinRE is never triggered
    subprocess.run(
        [str(utmctl), "exec", vm_id, "--cmd", "shutdown.exe", "/s", "/t", "0"],
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    try:
        wait_vm_status(utmctl, vm_id, "stopped", timeout=timeout)
        return
    except RuntimeError:
        run_cmd([str(utmctl), "stop", vm_id, "--force"], timeout=60)
        wait_vm_status(utmctl, vm_id, "stopped", timeout=60)


def cold_and_warm_boot_cycle(
    utmctl: Path, vm_id: str, bundle_path: Path, settle_seconds: float = 15.0, run_sfc: bool = True
) -> dict[str, Any]:
    graceful_stop_vm(utmctl, vm_id, timeout=90)

    bundle_gib = measure_bundle_gib(bundle_path)
    cold_t0 = time.perf_counter()
    run_cmd([str(utmctl), "start", vm_id], timeout=60)
    wait_vm_status(utmctl, vm_id, "started", timeout=60)
    cold_vm_started_s = round(time.perf_counter() - cold_t0, 3)
    cold_qga_s, cold_desktop_s = wait_qga_and_desktop(utmctl, vm_id, timeout=180)
    cold_qga_total_s = round(cold_vm_started_s + cold_qga_s, 3)
    cold_desktop_total_s = round(cold_vm_started_s + cold_desktop_s, 3)

    time.sleep(settle_seconds)
    host_idle = sample_host_rss_and_cpu(samples=5, interval_s=2.0)
    guest_state = collect_guest_state_snapshot(utmctl, vm_id, run_sfc=run_sfc)

    # Warm boot cycle (clean OS shutdown + immediate relaunch while host disk cache is warm)
    graceful_stop_vm(utmctl, vm_id, timeout=90)
    warm_t0 = time.perf_counter()
    run_cmd([str(utmctl), "start", vm_id], timeout=60)
    wait_vm_status(utmctl, vm_id, "started", timeout=60)
    warm_vm_started_s = round(time.perf_counter() - warm_t0, 3)
    warm_qga_s, warm_desktop_s = wait_qga_and_desktop(utmctl, vm_id, timeout=180)
    warm_qga_total_s = round(warm_vm_started_s + warm_qga_s, 3)
    warm_desktop_total_s = round(warm_vm_started_s + warm_desktop_s, 3)

    return {
        "vm_bundle_disk_gib": bundle_gib,
        "cold_boot": {
            "vm_started_seconds": cold_vm_started_s,
            "qga_ready_seconds": cold_qga_total_s,
            "desktop_ready_seconds": cold_desktop_total_s,
        },
        "warm_boot": {
            "vm_started_seconds": warm_vm_started_s,
            "qga_ready_seconds": warm_qga_total_s,
            "desktop_ready_seconds": warm_desktop_total_s,
        },
        "host_idle": host_idle,
        "guest_state": guest_state,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clone-vm-id", required=True)
    parser.add_argument("--primary-vm-id", required=True)
    parser.add_argument("--clone-bundle-path", type=Path, required=True)
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_EVIDENCE_DIR / "optimizer-benchmark.json")
    parser.add_argument("--settle-seconds", type=float, default=15.0)
    args = parser.parse_args()

    assert_clone_vm_safe(args.clone_vm_id, args.primary_vm_id)
    profile = json.loads(args.profile.read_text(encoding="utf-8"))
    validate_profile(profile)

    utmctl = discover_utmctl()
    # 1. Clean baseline measurement on the fresh clone
    baseline = cold_and_warm_boot_cycle(
        utmctl, args.clone_vm_id, args.clone_bundle_path, settle_seconds=args.settle_seconds, run_sfc=True
    )

    # 2. Push optimizer scripts + profile and apply interactively (Admin + User session)
    guest_powershell(utmctl, args.clone_vm_id, f"New-Item -ItemType Directory -Force -Path {ps_quote(GUEST_OPT_DIR)} | Out-Null")
    guest_profile = GUEST_OPT_DIR + "\\anticheat-minimal-win11-arm64.json"
    guest_apply = GUEST_OPT_DIR + "\\apply-optimizer.ps1"
    guest_rollback = GUEST_OPT_DIR + "\\rollback-optimizer.ps1"
    guest_push(utmctl, args.clone_vm_id, args.profile, guest_profile)
    guest_push(utmctl, args.clone_vm_id, DEFAULT_APPLY_SCRIPT, guest_apply)
    guest_push(utmctl, args.clone_vm_id, DEFAULT_ROLLBACK_SCRIPT, guest_rollback)

    apply_report = run_interactive_script(utmctl, args.clone_vm_id, "apply", guest_apply, guest_profile)
    # Test idempotency: run apply a second time and confirm snapshot_reused == True
    apply_idempotent_report = run_interactive_script(utmctl, args.clone_vm_id, "apply-idempotent", guest_apply, guest_profile)

    # 3. Measure optimized state after full reboot cycle
    optimized = cold_and_warm_boot_cycle(
        utmctl, args.clone_vm_id, args.clone_bundle_path, settle_seconds=args.settle_seconds, run_sfc=True
    )

    # 4. Run one-click rollback and verify consistency
    rollback_report = run_interactive_script(utmctl, args.clone_vm_id, "rollback", guest_rollback, guest_profile)

    # 5. Measure post-rollback state after reboot cycle
    rolled_back = cold_and_warm_boot_cycle(
        utmctl, args.clone_vm_id, args.clone_bundle_path, settle_seconds=args.settle_seconds, run_sfc=True
    )

    # Leave clone stopped cleanly
    graceful_stop_vm(utmctl, args.clone_vm_id, timeout=90)

    def delta(a: float, b: float) -> float:
        return round(b - a, 3)

    comparison = {
        "total_host_rss_mib_delta": delta(
            baseline["host_idle"]["total_host_rss_mib_mean"],
            optimized["host_idle"]["total_host_rss_mib_mean"],
        ),
        "qemu_rss_mib_delta": delta(
            baseline["host_idle"]["qemu_rss_mib_mean"],
            optimized["host_idle"]["qemu_rss_mib_mean"],
        ),
        "qemu_cpu_percent_delta": delta(
            baseline["host_idle"]["qemu_cpu_percent_mean"],
            optimized["host_idle"]["qemu_cpu_percent_mean"],
        ),
        "cold_boot_qga_seconds_delta": delta(
            baseline["cold_boot"]["qga_ready_seconds"],
            optimized["cold_boot"]["qga_ready_seconds"],
        ),
        "warm_boot_qga_seconds_delta": delta(
            baseline["warm_boot"]["qga_ready_seconds"],
            optimized["warm_boot"]["qga_ready_seconds"],
        ),
        "guest_process_count_delta": (
            optimized["guest_state"]["process_count"] - baseline["guest_state"]["process_count"]
        ),
        "guest_running_service_count_delta": (
            optimized["guest_state"]["running_service_count"]
            - baseline["guest_state"]["running_service_count"]
        ),
        "system_drive_used_gib_delta": delta(
            baseline["guest_state"]["system_drive_used_gib"],
            optimized["guest_state"]["system_drive_used_gib"],
        ),
        "idempotent_snapshot_reused": bool(apply_idempotent_report.get("snapshot_reused") is True),
        "rollback_consistent": bool(rollback_report.get("rollback_consistent") is True),
        "security_invariants_preserved_all_phases": all(
            phase["guest_state"].get("secure_boot_enabled") is True
            and phase["guest_state"].get("tpm_enabled") is True
            and phase["guest_state"].get("bcd_safe") is True
            and phase["guest_state"].get("prism_signed_ok") is True
            and phase["guest_state"].get("sfc_verifyonly_exit_code") == 0
            for phase in (baseline, optimized, rolled_back)
        ),
    }

    payload = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "isolated_clone_verified": True,
        "primary_vm_untouched": True,
        "source_digests": {
            "profile_json": sha256_file(args.profile),
            "apply_optimizer_ps1": sha256_file(DEFAULT_APPLY_SCRIPT),
            "rollback_optimizer_ps1": sha256_file(DEFAULT_ROLLBACK_SCRIPT),
            "benchmark_optimizer_clone_py": sha256_file(Path(__file__).resolve()),
        },
        "phases": {
            "clean_baseline": baseline,
            "optimized": optimized,
            "rolled_back": rolled_back,
        },
        "apply_report": apply_report,
        "apply_idempotent_report": apply_idempotent_report,
        "rollback_report": rollback_report,
        "comparison": comparison,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(clean_value(payload), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"complete": True, "comparison": comparison}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Read-only Guest gate bound to the recovered module-b security baseline."""
from __future__ import annotations
import hashlib
import subprocess
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from benchmark_support import (SCRIPT_DIR, WORKSPACE_ROOT, GUEST_DIR, GuestSession, ps_quote,
    sha256_file, validate_guest_environment, writable_path, write_json, guest_json_query)

BASELINE_FIELDS = ("captured_at_utc", "boot_time_utc", "secure_boot_enabled", "tpm",
                   "hypervisor_present", "vbs_status", "security_services_running", "bcd_security")
SUCCESS_FIELDS = ("os_query_succeeded", "session_query_succeeded", "session_matches_console",
    "logged_in", "unlocked", "quiescence_query_succeeded", "secure_boot_query_succeeded",
    "driver_service_query_succeeded", "owned_services_absent", "tpm_query_succeeded",
    "device_guard_query_succeeded", "code_integrity_query_succeeded", "bcd_query_succeeded",
    "read_only", "temporary_directory_scoped", "preflight_gates_passed")


def _utc(value: object) -> datetime:
    if not isinstance(value, str):
        raise RuntimeError("preflight timestamps must be UTC strings")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise RuntimeError("preflight timestamp is invalid") from None
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 0:
        raise RuntimeError("preflight timestamps must carry the UTC offset")
    return parsed


def _security_baseline(baseline: dict) -> None:
    if not isinstance(baseline, dict) or any(field not in baseline for field in BASELINE_FIELDS):
        raise RuntimeError("recovered security baseline is incomplete")
    if baseline["secure_boot_enabled"] is not True:
        raise RuntimeError("recovered baseline does not enable Secure Boot")
    if type(baseline["hypervisor_present"]) is not bool or type(baseline["vbs_status"]) is not int:
        raise RuntimeError("recovered virtualization baseline has invalid types")
    services = baseline["security_services_running"]
    if not isinstance(services, list) or any(type(value) is not int for value in services):
        raise RuntimeError("recovered security-service baseline has invalid types")
    tpm = baseline["tpm"]
    if not isinstance(tpm, dict):
        raise RuntimeError("recovered TPM baseline is incomplete")
    for field in ("present", "enabled", "activated", "owned"):
        if type(tpm.get(field)) is not bool:
            raise RuntimeError("recovered TPM baseline has missing or invalid state")
    if not isinstance(tpm.get("specification_version"), str) or not tpm["specification_version"]:
        raise RuntimeError("recovered TPM version is unknown")
    if not isinstance(baseline["bcd_security"], list):
        raise RuntimeError("recovered BCD baseline is not an array")
    _safe_bcd_lines(baseline["bcd_security"])
    if _utc(baseline["boot_time_utc"]) > _utc(baseline["captured_at_utc"]):
        raise RuntimeError("recovered baseline boot time is later than its capture")


def _safe_bcd_lines(lines: list) -> None:
    for line in lines:
        if not isinstance(line, str):
            raise RuntimeError("BCD evidence contains an invalid element")
        match = re.fullmatch(r"\s*(testsigning|nointegritychecks)\s+(\S+)\s*", line, re.IGNORECASE)
        if not match or match.group(2).lower() not in ("no", "off", "false", "disabled", "0", "否"):
            raise RuntimeError("BCD evidence enables or cannot classify an unsafe switch")


def load_baseline(root: Path = WORKSPACE_ROOT) -> tuple[dict, str]:
    path = root / "handoff" / "phase-2" / "evidence" / "window-b" / "b2-recovery-boot-security-result.json"
    try:
        wrapper = json.loads(path.read_text(encoding="utf-8-sig"))
        if type(wrapper.get("exit_code")) is not int or wrapper["exit_code"] != 0 or wrapper.get("recovery_pending") is not False:
            raise RuntimeError("security recovery baseline has not completed successfully")
        raw = wrapper.get("stdout")
        if not isinstance(raw, str):
            raise RuntimeError("security recovery baseline lacks its actual snapshot")
        snapshot = json.loads(raw)
        baseline = {field: snapshot[field] for field in BASELINE_FIELDS if field in snapshot}
        _security_baseline(baseline)
        return baseline, sha256_file(path)
    except (OSError, ValueError, TypeError):
        raise RuntimeError("trusted recovered security baseline could not be loaded") from None


def discover_owned_services(root: Path = WORKSPACE_ROOT,
                            guest: GuestSession | None = None) -> tuple[list[str], str]:
    paths = list(root.glob("Modules/*/tests/verify-lifecycle.ps1"))
    if len(paths) > 1:
        raise RuntimeError("driver lifecycle source is ambiguous")
    if len(paths) == 1:
        source = paths[0].read_text(encoding="utf-8-sig")
        assignments = re.findall(r"(?im)\$(ServiceName|FailureServiceName)\s*=\s*(['\"])([^'\"\r\n]+)\2(?=\s*(?:[,);\r\n]|$))", source)
        values = {}
        for field, _quote, value in assignments:
            if field in values:
                raise RuntimeError("driver service defaults are ambiguous")
            values[field] = value
        digest = sha256_file(paths[0])
    else:
        if guest is None:
            raise RuntimeError("trusted driver lifecycle source is unavailable")
        query = r"""$ErrorActionPreference='Stop';
$sourcePath=Join-Path $env:SystemDrive 'lab-b2\source-native\tests\verify-lifecycle.ps1';
$text=Get-Content -Raw -LiteralPath $sourcePath;
$pattern='(?im)\$(ServiceName|FailureServiceName)\s*=\s*([''\"])([^''\"\r\n]+)\2(?=\s*(?:[,);\r\n]|$))';
$found=[regex]::Matches($text,$pattern);
if($found.Count -ne 2){throw 'driver service defaults are ambiguous'};
$values=@{};
foreach($match in $found){
    $key=$match.Groups[1].Value;
    if($values.ContainsKey($key)){throw 'duplicate driver service default'};
    $values[$key]=$match.Groups[3].Value
};
$values['source_sha256']=(Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant();
$values|ConvertTo-Json -Compress"""
        try:
            values = guest_json_query(guest, query)
            digest = values.pop("source_sha256")
        except (ValueError, KeyError, TypeError):
            raise RuntimeError("trusted Guest lifecycle source did not return valid defaults") from None
    if set(values) != {"ServiceName", "FailureServiceName"} or any(
            not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]+", value) for value in values.values()):
        raise RuntimeError("two literal driver service defaults are required")
    if len(set(values.values())) != 2 or not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise RuntimeError("driver lifecycle provenance is invalid")
    return [values["ServiceName"], values["FailureServiceName"]], digest


def validate_preflight(actual: dict, baseline: dict) -> None:
    _security_baseline(baseline)
    if not isinstance(actual, dict):
        raise RuntimeError("actual preflight snapshot must be an object")
    validate_guest_environment(actual)
    if any(actual.get(field) is not True for field in SUCCESS_FIELDS):
        raise RuntimeError("Guest preflight has an unknown or failed required query")
    if actual.get("owner") != "@DNPMBHC" or actual.get("baseline_comparison_required") is not True:
        raise RuntimeError("Guest preflight schema or provenance is invalid")
    session = actual.get("console_session_id")
    if type(session) is not int or not 0 < session < 0xFFFFFFFF:
        raise RuntimeError("Guest has no nonzero interactive console session")
    for field, value in (("session_state", 0), ("session_flags", 1),
                         ("session_flags_offset", 16), ("wts_info_ex_struct_bytes", 232),
                         ("forbidden_process_count", 0), ("forbidden_running_task_count", 0),
                         ("remaining_driver_service_count", 0)):
        if type(actual.get(field)) is not int or actual[field] != value:
            raise RuntimeError("Guest session, quiescence, or service gate did not pass")
    returned = actual.get("wts_returned_bytes")
    if type(returned) is not int or returned < 232:
        raise RuntimeError("WTSINFOEX evidence is truncated")
    expected_services = actual.get("expected_absent_driver_service_count")
    if type(expected_services) is not int or expected_services != 2:
        raise RuntimeError("driver cleanup baseline was not supplied")
    flags = actual.get("bcd_flags")
    if not isinstance(flags, dict) or any(flags.get(field) not in ("off", "absent")
                                         for field in ("testsigning", "nointegritychecks")):
        raise RuntimeError("BCD security switches are enabled or unknown")
    if not isinstance(actual.get("bcd_security"), list):
        raise RuntimeError("actual BCD evidence is missing")
    _safe_bcd_lines(actual["bcd_security"])
    if actual.get("code_integrity_test_signing") is not False:
        raise RuntimeError("running kernel still enables test signing")
    for field in ("secure_boot_enabled", "hypervisor_present", "vbs_status", "security_services_running"):
        if field not in actual or type(actual[field]) is not type(baseline[field]) or actual[field] != baseline[field]:
            raise RuntimeError(f"Guest security baseline changed: {field}")
    if any(type(value) is not int for value in actual["security_services_running"]):
        raise RuntimeError("actual security-service evidence has invalid types")
    actual_tpm = actual.get("tpm")
    if not isinstance(actual_tpm, dict):
        raise RuntimeError("actual TPM evidence is missing")
    for field in ("present", "enabled", "activated", "owned", "specification_version"):
        if field not in actual_tpm or type(actual_tpm[field]) is not type(baseline["tpm"][field]) or actual_tpm[field] != baseline["tpm"][field]:
            raise RuntimeError("actual TPM state differs from the recovered baseline")
    expected_hvci = 2 in baseline["security_services_running"]
    if actual.get("hvci_running") is not expected_hvci or actual.get("hvci_kernel_enforced") is not expected_hvci:
        raise RuntimeError("actual HVCI state differs from the recovered baseline")
    captured = _utc(actual.get("captured_at_utc"))
    if captured < _utc(baseline["captured_at_utc"]) or _utc(actual.get("boot_time_utc")) > captured:
        raise RuntimeError("actual preflight timing does not follow the recovered baseline")


def stage_preflight_script(guest: GuestSession, source_path: Path) -> tuple[str, str]:
    """Stage only this window's artifact; leave Guest security and other jobs untouched."""
    data = source_path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    guest_path = GUEST_DIR + r"\guest-preflight.ps1"
    guest.powershell("New-Item -ItemType Directory -Force -Path " + ps_quote(GUEST_DIR) + "|Out-Null")
    try:
        result = subprocess.run([str(guest.utmctl), "file", "push", guest.vm_id, guest_path],
                                input=data, capture_output=True, check=False, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("owned preflight artifact could not be staged") from None
    if result.returncode:
        raise RuntimeError("owned preflight artifact upload failed")
    remote_digest = guest.powershell("(Get-FileHash -Algorithm SHA256 -LiteralPath " + ps_quote(guest_path) + ").Hash.ToLowerInvariant()")
    if remote_digest.lower() != digest:
        raise RuntimeError("owned preflight artifact SHA-256 differs in vm-a")
    return guest_path, digest


def collect_preflight(guest: GuestSession, output: Path) -> dict:
    output = writable_path(output)
    output.mkdir(parents=True, exist_ok=True)
    baseline, baseline_sha = load_baseline()
    services, lifecycle_sha = discover_owned_services(guest=guest)
    source_path = SCRIPT_DIR / "guest_preflight.ps1"
    staged_path, source_sha = stage_preflight_script(guest, source_path)
    invocation = ("& ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath " + ps_quote(staged_path) + "))) -ExpectedAbsentDriverServices @(" +
                  ",".join(ps_quote(value) for value in services) + ")")
    try:
        actual = guest_json_query(guest, invocation)
    except (ValueError, TypeError):
        raise RuntimeError("actual read-only preflight did not return a JSON object") from None
    binding = {"baseline_sha256": baseline_sha, "preflight_ps1_sha256": source_sha,
               "preflight_py_sha256": sha256_file(SCRIPT_DIR / "guest_preflight.py"),
               "lifecycle_source_sha256": lifecycle_sha, "service_baseline_count": len(services),
               "recovered_security_baseline": baseline}
    if sha256_file(source_path) != source_sha:
        raise RuntimeError("preflight source changed during its actual execution")
    try:
        validate_preflight(actual, baseline)
    except RuntimeError:
        write_json(output / "guest-preflight.json", {"passed": False, "actual": actual, "binding": binding})
        raise
    result = dict(actual, passed=True, baseline_verified=True, **binding)
    write_json(output / "guest-preflight.json", result)
    return result

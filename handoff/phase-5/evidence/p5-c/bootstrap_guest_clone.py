#!/usr/bin/env python3
"""Standard tools and preflight on the independently proved C clone. Owner: @DNPMBHC."""
import argparse
import base64
import importlib.util
import json
import subprocess
import time
import uuid
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runtime_guard", EVIDENCE / "run_guest_runtime_validation.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
clone = runtime.clone


def powershell(identifier, source, timeout=60):
    token = uuid.uuid4().hex
    script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';try{$value=& {" + source + "};"
    script += "@{query_token='" + token + "';value=$value}|ConvertTo-Json -Depth 8 -Compress}catch{@{query_token='" + token + "';error_type=$_.Exception.GetType().Name;error_id=($_.FullyQualifiedErrorId -split ',')[0]}|ConvertTo-Json -Compress;exit 1}"
    encoded = base64.b64encode(script.encode("utf-16-le")).decode()
    command = [str(clone.controller()), "exec", "--hide", identifier]
    use_input = len(encoded) > 20000
    if use_input: command.append("--input")
    command += ["--cmd", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "-NoProfile", "-NonInteractive"]
    command += ["-Command", "-"] if use_input else ["-EncodedCommand", encoded]
    result = subprocess.run(command, input=script + "\n\n" if use_input else None,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode or len(result.stdout) > 1048576:
        try:
            failed = json.loads(result.stdout.lstrip("\ufeff"))
            if failed.get("query_token") == token:
                safe = {"owner":"@DNPMBHC", "exit_code":result.returncode,
                        "source_sha256": __import__("hashlib").sha256(source.encode()).hexdigest()}
                for key in ("error_type", "error_id"):
                    value = failed.get(key, "")
                    if __import__("re").fullmatch(r"[A-Za-z0-9_-]{1,128}", value): safe[key] = value
                clone.save(EVIDENCE / "guest-management-failure-diagnostic.json", safe)
        except ValueError:
            pass
        raise RuntimeError("guest_management_command_failed")
    response = json.loads(result.stdout.lstrip("\ufeff"))
    if response.get("query_token") != token: raise RuntimeError("guest_response_identity_mismatch")
    return response["value"]


def start_hidden(identifier):
    state = clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower()
    if state not in ("started", "paused", "stopped"): raise RuntimeError("owned_clone_state_invalid")
    if state != "started": clone.command([str(clone.controller()), "start", "--hide", identifier], timeout=30)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            if powershell(identifier, "@{agent_ready=$true}", timeout=20).get("agent_ready") is True: return
        except (RuntimeError, ValueError, subprocess.TimeoutExpired):
            time.sleep(1)
    raise RuntimeError("owned_clone_agent_not_ready")


def preflight(identifier):
    query = r"""
$tpm=Get-CimInstance -Namespace root\CIMV2\Security\MicrosoftTpm -ClassName Win32_Tpm
$driver=Get-CimInstance Win32_SystemDriver -Filter "Name='VioGpu3D'"
$path=if($null -ne $driver){$driver.PathName.Trim('"')}else{$null}
$underWindows=$path -and $path.StartsWith($env:SystemRoot,[StringComparison]::OrdinalIgnoreCase)
$sig=if($underWindows -and (Test-Path -LiteralPath $path)){Get-AuthenticodeSignature -LiteralPath $path}else{$null}
$adapters=@(Get-CimInstance Win32_VideoController | ForEach-Object {
  @{virtio_3d=($_.Description -eq 'Red Hat VirtIO GPU 3D controller');error_code=$_.ConfigManagerErrorCode;
    adapter_ram=[long]$_.AdapterRAM;driver_version=[string]$_.DriverVersion}
})
$bcd=(bcdedit /enum '{current}' | Out-String)
@{owner='@DNPMBHC';secure_boot=(Confirm-SecureBootUEFI);tpm_present=($null -ne $tpm);
  tpm_enabled=[bool]$tpm.IsEnabled_InitialValue;tpm_2=([string]$tpm.SpecVersion -match '2\.0');
  unsafe_bcd_options=($bcd -match '(?im)^\s*(testsigning|nointegritychecks)\s+(Yes|On|True|1|是|启用)\s*$');
  driver_running=($driver.State -eq 'Running');driver_signature_valid=($sig.Status -eq 'Valid');
  actual_driver_service='VioGpu3D';driver_path_under_windows=[bool]$underWindows;
  whql_publisher=($sig.SignerCertificate.Subject -match 'Microsoft Windows Hardware Compatibility Publisher');
  session1_shell_observed=(@(Get-Process -Name explorer -ErrorAction SilentlyContinue|Where-Object SessionId -eq 1).Count -gt 0);
  adapters=$adapters}
"""
    report = powershell(identifier, query)
    if report.get("owner") != "@DNPMBHC" or not isinstance(report.get("adapters"), list):
        raise RuntimeError("guest_security_response_invalid")
    if not all(report.get(k) is True for k in ("secure_boot", "tpm_present", "tpm_enabled", "tpm_2")) \
            or report.get("unsafe_bcd_options") is not False:
        raise RuntimeError("guest_security_baseline_failed")
    report["driver_ready"] = all(report.get(k) is True for k in ("driver_running", "driver_signature_valid", "whql_publisher")) \
        and any(adapter.get("virtio_3d") is True and adapter.get("error_code") == 0 for adapter in report["adapters"])
    report.update(owner="@DNPMBHC", actual_feature_level_verified=False,
                  game_AdapterRAM_check="unknown", primary_vm_control_actions=0)
    clone.save(EVIDENCE / "guest-security-current.json", report)
    return report


def install_driver(identifier):
    present = powershell(identifier, r"@{count=@(Get-CimInstance Win32_CDROMDrive|Where-Object {Test-Path -LiteralPath (Join-Path $_.Drive 'Drivers\viogpu3d\w11\ARM64\viogpu3d.inf')}).Count}")
    script = """on run argv
      with timeout of 180 seconds
        tell application id "com.utmapp.UTM"
          install guest tools (virtual machine id (item 1 of argv))
        end tell
      end timeout
    end run"""
    if present.get("count") == 0:
        clone.command(["osascript", "-e", script, "--", identifier], timeout=180)
    elif present.get("count") != 1:
        raise RuntimeError("official_driver_inf_not_unique")
    print(json.dumps({"owner": "@DNPMBHC", "stage": "official_whql_pnputil_install"}), flush=True)
    query = r"""
$inf=@(Get-CimInstance Win32_CDROMDrive|ForEach-Object {
  $candidate=Join-Path $_.Drive 'Drivers\viogpu3d\w11\ARM64\viogpu3d.inf'
  if(Test-Path -LiteralPath $candidate){$candidate}
})
if($inf.Count -ne 1){throw 'official_driver_inf_not_unique'}
$catalog=Join-Path (Split-Path $inf[0]) 'viogpu3d.cat'
$signature=Get-AuthenticodeSignature -LiteralPath $catalog
if($signature.Status -ne 'Valid' -or
  $signature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
  throw 'official_driver_catalog_not_whql'
}
$arguments=@('/add-driver', ('"'+$inf[0]+'"'), '/install')
$process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') -ArgumentList $arguments -Wait -PassThru
@{owner='@DNPMBHC';exit_code=$process.ExitCode;inf_sha256=(Get-FileHash -LiteralPath $inf[0]).Hash.ToLowerInvariant();
  catalog_sha256=(Get-FileHash -LiteralPath $catalog).Hash.ToLowerInvariant();catalog_signature_valid=$true}
"""
    report = powershell(identifier, query, timeout=180)
    clone.save(EVIDENCE / "guest-whql-driver-install.json", report)
    if report.get("exit_code") not in (0, 3010): raise RuntimeError("official_driver_install_failed")
    clone.command([str(clone.controller()), "stop", "--hide", identifier, "--request"], timeout=30)
    deadline = time.monotonic() + 60
    while clone.command([str(clone.controller()), "status", identifier]).decode().strip().lower() != "stopped":
        if time.monotonic() > deadline: raise RuntimeError("driver_install_shutdown_not_confirmed")
        time.sleep(0.5)
    start_hidden(identifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preflight", "install-driver"))
    args = parser.parse_args()
    try:
        _, identifier = runtime.authorize()
        start_hidden(identifier)
        initial = preflight(identifier)
        if args.action == "install-driver" and not initial["driver_ready"]:
            install_driver(identifier)
            initial = preflight(identifier)
        print(json.dumps({"owner": "@DNPMBHC", "driver_ready": initial["driver_ready"],
                          "secure_boot_verified": True, "tpm_2_verified": True,
                          "actual_feature_level_verified": False, "game_AdapterRAM_check": "unknown"}), flush=True)
        return 0
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired):
        print(json.dumps({"owner": "@DNPMBHC", "error_code": "guarded_guest_bootstrap_not_completed"}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

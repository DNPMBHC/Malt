#!/usr/bin/env python3
"""Apply the unchanged, hash-bound minimal profile to the owned clone. Owner: @DNPMBHC."""
import argparse
import importlib.util
import json
import subprocess
import time
import uuid
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[3]
spec = importlib.util.spec_from_file_location("guest_bootstrap", EVIDENCE / "bootstrap_guest_clone.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
clone = bootstrap.clone
PINNED = {
    "apply-optimizer.ps1": "84c0b2fbac89240c25176b09bd7c108b6b8318265cd7ae3c9f5a5bdffa8a4a11",
    "rollback-optimizer.ps1": "d71161af5673d1ae205230377ae7e256f32091e98f6a3ab8e046a227739ab768",
    "anticheat-minimal-win11-arm64.json": "906b01c178307f7cec917a90a1d96de62e123d69e41282f3b0276659ef77f76a",
}


def inputs():
    files = {}
    for name, expected in PINNED.items():
        matches = [p for p in ROOT.glob("**/" + name) if clone.digest(p) == expected]
        if len(matches) != 1: raise RuntimeError("optimizer_source_identity_not_unique")
        files[name] = matches[0]
    return files


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def prepare(identifier, files):
    directory = r"C:\guest-shell-lab\minimal"
    bootstrap.powershell(identifier, "New-Item -ItemType Directory -Force -Path " + quote(directory) + "|Out-Null;@{created=$true}")
    for name, path in files.items():
        destination = directory + "\\" + name
        result = subprocess.run([str(clone.controller()), "file", "push", identifier, destination],
                                input=path.read_bytes(), capture_output=True, timeout=60)
        if result.returncode: raise RuntimeError("optimizer_transfer_failed")
        actual = bootstrap.powershell(identifier, "@{sha256=(Get-FileHash -LiteralPath " + quote(destination) + ").Hash.ToLowerInvariant()}")
        if actual.get("sha256") != PINNED[name]: raise RuntimeError("guest_optimizer_source_mismatch")
    return directory


def run_interactive(identifier, directory, action):
    token = uuid.uuid4().hex
    task_name = "guest-shell-minimal-" + token
    wrapper = directory + "\\run-" + token + ".ps1"
    output = directory + "\\result-" + token + ".json"
    script_path = directory + "\\" + action + "-optimizer.ps1"
    profile = directory + r"\anticheat-minimal-win11-arm64.json"
    body = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"
    body += "$session=[Diagnostics.Process]::GetCurrentProcess().SessionId;"
    body += "try{if($session -ne 1){throw 'session_one_required'};$raw=& " + quote(script_path)
    body += " -ProfilePath " + quote(profile) + " -StateDirectory " + quote(directory)
    body += ";$data=($raw -join [Environment]::NewLine)|ConvertFrom-Json;"
    body += "$result=@{owner='@DNPMBHC';request_id='" + token + "';session_id=$session;exit_code=0;report=$data}}"
    body += "catch{$result=@{owner='@DNPMBHC';request_id='" + token + "';session_id=$session;exit_code=1;error_code='optimizer_execution_failed'}};"
    body += "[IO.File]::WriteAllText(" + quote(output) + ",($result|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))"
    # RemoteSigned applies only to this verified local script process; persistent policies remain unchanged.
    encoded = __import__("base64").b64encode(body.encode()).decode()
    launch = "$policies=@(Get-ExecutionPolicy -List|Where-Object {$_.Scope -in @('MachinePolicy','UserPolicy') -and $_.ExecutionPolicy -notin @('Undefined','RemoteSigned')});if($policies.Count){throw 'enforced_script_policy_requires_operator'};"
    launch += "$shell=@(Get-CimInstance Win32_Process -Filter \"Name='explorer.exe'\"|Where-Object SessionId -eq 1);"
    launch += "if($shell.Count -ne 1){throw 'session_one_owner_not_unique'};"
    launch += "$owner=Invoke-CimMethod -InputObject $shell[0] -MethodName GetOwner;"
    launch += "if($owner.ReturnValue -ne 0){throw 'session_one_owner_unavailable'};$user=$owner.Domain+'\\'+$owner.User;"
    launch += "[IO.File]::WriteAllBytes(" + quote(wrapper) + ",[Convert]::FromBase64String('" + encoded + "'));"
    arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + wrapper + '"'
    launch += "$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\powershell.exe') -Argument " + quote(arguments) + ";"
    launch += "$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest;"
    launch += "Register-ScheduledTask -TaskName " + quote(task_name) + " -Action $action -Principal $principal|Out-Null;"
    launch += "Start-ScheduledTask -TaskName " + quote(task_name) + ";@{started=$true}"
    cleanup = "Stop-ScheduledTask -TaskName " + quote(task_name) + " -ErrorAction SilentlyContinue;"
    cleanup += "Unregister-ScheduledTask -TaskName " + quote(task_name) + " -Confirm:$false -ErrorAction SilentlyContinue;"
    cleanup += "Remove-Item -LiteralPath @(" + quote(wrapper) + "," + quote(output) + ") -ErrorAction SilentlyContinue;@{cleaned=$true}"
    try:
        bootstrap.powershell(identifier, launch)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            query = "if(Test-Path -LiteralPath " + quote(output) + "){Get-Content -Raw -LiteralPath " + quote(output) + "|ConvertFrom-Json}else{$task=Get-ScheduledTask -TaskName " + quote(task_name) + ";$info=$task|Get-ScheduledTaskInfo;@{pending=$true;task_state=[string]$task.State;task_exit=$info.LastTaskResult}}"
            response = bootstrap.powershell(identifier, query)
            if response.get("pending") is not True:
                if response.get("request_id") != token or response.get("owner") != "@DNPMBHC" or response.get("session_id") != 1 or response.get("exit_code") != 0:
                    raise RuntimeError("optimizer_result_identity_or_exit_failed")
                report = response["report"]
                if report.get("profile_sha256") != PINNED["anticheat-minimal-win11-arm64.json"] or report.get("script_sha256") != PINNED[action + "-optimizer.ps1"]:
                    raise RuntimeError("optimizer_result_source_mismatch")
                if report.get("owner") != "@DNPMBHC" or report.get("security_invariants_passed") is not True:
                    raise RuntimeError("optimizer_security_invariants_failed")
                if action == "rollback" and report.get("rollback_consistent") is not True:
                    raise RuntimeError("optimizer_rollback_not_verified")
                report["profile_id"] = "minimal-profile"
                report.update(session_id=1, request_id=token, primary_vm_control_actions=0,
                              script_process_execution_policy="RemoteSigned", persistent_execution_policy_changed=False)
                clone.save(EVIDENCE / ("guest-minimal-" + action + ".json"), report)
                return report
            if response.get("task_state") == "Ready" and response.get("task_exit") not in (0, None):
                clone.save(EVIDENCE / ("guest-minimal-" + action + "-task-failure.json"),
                           {"owner": "@DNPMBHC", "request_id": token, "task_exit": response["task_exit"],
                            "persistent_execution_policy_changed": False})
                raise RuntimeError("optimizer_task_failed_before_result")
            time.sleep(0.5)
        raise RuntimeError("optimizer_interactive_timeout")
    finally:
        bootstrap.powershell(identifier, cleanup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "apply", "rollback"), default="inspect", nargs="?")
    args = parser.parse_args()
    try:
        files = inputs()
        if args.action == "inspect":
            print(json.dumps({"owner": "@DNPMBHC", "sources_match_frozen_profile": True, "vm_control_actions": 0}))
            return 0
        _, identifier = bootstrap.runtime.authorize()
        bootstrap.start_hidden(identifier)
        security = bootstrap.preflight(identifier)
        if not security["driver_ready"]: raise RuntimeError("whql_3d_driver_required_before_optimizer")
        directory = prepare(identifier, files)
        report = run_interactive(identifier, directory, args.action)
        print(json.dumps({"owner": "@DNPMBHC", "action": args.action, "session_id": 1,
                          "security_invariants_passed": report["security_invariants_passed"]}))
        return 0
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        code = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(json.dumps({"owner": "@DNPMBHC", "error_code": code}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

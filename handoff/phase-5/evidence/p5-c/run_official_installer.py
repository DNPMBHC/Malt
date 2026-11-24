#!/usr/bin/env python3
"""Owned-clone installer launch and authenticated native process observation. Owner: @DNPMBHC."""
import argparse
import importlib.util
import json
import subprocess
import time
import uuid
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("owned_client_inspection", EVIDENCE / "inspect_guest_display_modes.py")
inspection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspection)
bootstrap = inspection.bootstrap
RECORD = EVIDENCE / "official-installer-session.json"
HELPER = r"C:\guest-shell-lab\desktop-helper.exe"

def status(identifier, token):
    result = bootstrap.powershell(identifier, "& '" + HELPER + "' 'status' '" + token + "'|ConvertFrom-Json")
    if result.get("requestID") != token:
        raise RuntimeError("installer_session_identity_mismatch")
    safe = {k: result.get(k) for k in ("requestID", "controllerPID", "targetPID", "targetCreationTime", "sessionID", "state", "rootExited", "rootExitCode", "activeProcessCount", "cancelled", "exitCode", "error", "win32Error")}
    return safe

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("launch", "inspect"))
    args = parser.parse_args()
    try:
        _, identifier = bootstrap.runtime.authorize()
        bootstrap.start_hidden(identifier)
        if args.action == "launch":
            if RECORD.exists():
                previous = json.loads(RECORD.read_text())
                if previous.get("clone_identifier") != identifier:
                    raise RuntimeError("installer_record_owner_mismatch")
                observed = status(identifier, previous["request_id"])
                if observed.get("state") != "exited":
                    raise RuntimeError("existing_installer_requires_observation")
            trust = json.loads((EVIDENCE / "official-installer-own-guest-trust.json").read_text())
            if trust.get("owner") != "@DNPMBHC" or trust.get("verified") is not True:
                raise RuntimeError("verified_official_installer_required")
            token = str(uuid.uuid4())
            target = trust.get("guest_installer_path", r"C:\guest-shell-lab\official-installer.exe")
            if trust.get("clone_identifier", identifier) != identifier:
                raise RuntimeError("installer_trust_clone_mismatch")
            payload = inspection.manifest(target, [])
            script = """on run argv
              tell application id "com.utmapp.UTM"
                set vm to virtual machine id (item 1 of argv)
                set nativeArguments to {"launch", item 3 of argv, item 4 of argv}
                set p to execute of vm at (item 2 of argv) with arguments nativeArguments
                return id of p as text
              end tell
            end run"""
            controller_pid = int(bootstrap.clone.command(["osascript", "-e", script, "--", identifier, HELPER, token, payload]).decode().strip())
            record = {"owner": "@DNPMBHC", "clone_identifier": identifier, "request_id": token,
                      "controller_pid": controller_pid, "installer_started": True,
                      "human_login_completed": False, "primary_vm_control_actions": 0}
            bootstrap.clone.save(RECORD, record)
        else:
            record = json.loads(RECORD.read_text())
            if record.get("owner") != "@DNPMBHC" or record.get("clone_identifier") != identifier:
                raise RuntimeError("installer_record_owner_mismatch")
        deadline = time.monotonic() + 30
        while True:
            observed = status(identifier, record["request_id"])
            if observed.get("state") not in ("starting", "failed") or time.monotonic() >= deadline: break
            time.sleep(0.5)
        if observed.get("sessionID") != 1 or observed.get("controllerPID") != record["controller_pid"]:
            raise RuntimeError("installer_native_identity_unconfirmed")
        record.update(observed=observed, session_one_verified=True)
        bootstrap.clone.save(RECORD, record)
        print(json.dumps({"owner": "@DNPMBHC", "session_one_verified": True, "state": observed["state"],
                          "root_exit_code": observed["rootExitCode"], "human_login_completed": False}))
        return 0
    except Exception as error:
        print(json.dumps({"owner": "@DNPMBHC", "error_code": str(error) if isinstance(error, RuntimeError) else type(error).__name__}))
        return 1

if __name__ == "__main__":
    raise SystemExit(main())

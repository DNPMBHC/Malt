#!/usr/bin/env python3
"""Inspect real Session 1 display modes and test native dimensions without applying. Owner: @DNPMBHC."""
import base64
import importlib.util
import json
import struct
import subprocess
import time
import uuid
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("display_inspection_bootstrap", EVIDENCE / "bootstrap_guest_clone.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def manifest(program, args):
    def field(value):
        data = value.encode()
        return struct.pack("<I", len(data)) + data
    data = b"MBD1" + field(program) + struct.pack("<I", len(args))
    data += b"".join(field(arg) for arg in args) + struct.pack("<I", 0)
    if len(data) > 16384: raise RuntimeError("inspection_manifest_exceeds_native_helper_limit")
    return base64.b64encode(data).decode()


def execute_known_script(identifier, source):
    token = str(uuid.uuid4())
    helper = r"C:\guest-shell-lab\desktop-helper.exe"
    args = ["-NoProfile", "-NonInteractive", "-EncodedCommand", base64.b64encode(source.encode("utf-16-le")).decode()]
    payload = manifest(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", args)
    controller = subprocess.Popen([str(bootstrap.clone.controller()), "exec", "--hide", identifier,
                                   "--cmd", helper, "launch", token, payload],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 60
    identity = None
    try:
        while time.monotonic() < deadline:
            value = bootstrap.powershell(identifier, "& '" + helper + "' 'status' '" + token + "'|ConvertFrom-Json")
            if value.get("requestID") != token: raise RuntimeError("request_identity_mismatch")
            if value.get("state") in ("starting", "failed"):
                if value.get("state") == "failed" and value.get("error") not in ("requestNotReady", "requestMissing", "controllerExited"):
                    raise RuntimeError("interactive_probe_failed")
                time.sleep(0.2)
                continue
            observed = (value["controllerPID"], value["targetPID"], value["targetCreationTime"], value["sessionID"])
            if observed[0] <= 0 or observed[3] != 1: raise RuntimeError("interactive_identity_invalid")
            if identity is not None and observed != identity: raise RuntimeError("interactive_identity_changed")
            identity = observed
            if value["state"] == "exited":
                if value.get("cancelled") or value.get("activeProcessCount") != 0 or value.get("rootExitCode") != 0:
                    raise RuntimeError("interactive_probe_exit_failed")
                output = base64.b64decode(value["stdoutBase64"])
                if len(output) > 1048576: raise RuntimeError("probe_output_too_large")
                return json.loads(output.decode("utf-8-sig")), value["rootExitCode"]
            time.sleep(0.2)
        raise RuntimeError("interactive_probe_timeout")
    finally:
        cleanup = bootstrap.powershell(identifier, "& '" + helper + "' 'cancel' '" + token + "'|ConvertFrom-Json")
        if cleanup.get("state") != "exited" and not (cleanup.get("launchSuppressed") is True and cleanup.get("targetPID") == 0):
            cleanup = bootstrap.powershell(identifier, "& '" + helper + "' 'force-cancel' '" + token + "'|ConvertFrom-Json")
            if cleanup.get("state") != "exited" and not cleanup.get("launchSuppressed"):
                raise RuntimeError("owned_interactive_cleanup_unconfirmed")
        try:
            controller.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            controller.kill()
            controller.communicate(timeout=5)


def main():
    try:
        _, identifier = bootstrap.runtime.authorize()
        bootstrap.start_hidden(identifier)
        runtime = next(next(bootstrap.runtime.ROOT.glob("*/*/Package.swift")).parent.glob("Sources/*/Runtime"))
        raw = (runtime / "GuestSurfaceDisplaySync.swift").read_text().split('private static let helper = #"""', 1)[1].split('"""#', 1)[0]
        raw = __import__("re").sub(r"\s+", " ", raw)
        script = "$ErrorActionPreference='Stop';if([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 1){throw 'session1_required'};"
        script += "Add-Type -TypeDefinition @'\n" + raw + r"""
public static class NativeModeTest {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsExW(
 string device, ref GuestDisplayModeHelper.Mode mode, IntPtr window, uint flags, IntPtr param);
 public static int Test(string device, uint width, uint height, uint refresh) {
  var mode=GuestDisplayModeHelper.Query(device,-1);
  mode.width=width;mode.height=height;mode.frequency=refresh;
  mode.fields=0x80000|0x100000|0x400000|0x40000;
  return ChangeDisplaySettingsExW(device,ref mode,IntPtr.Zero,2,IntPtr.Zero);
 }
}
""" + "\n'@ -Language CSharp|Out-Null;"
        script += "$device=[GuestDisplayModeHelper]::Primary();$modes=@();for($n=0;$n -lt 4096;$n++){try{$m=[GuestDisplayModeHelper]::Query($device,$n)}catch{break};$modes+=@{width=[int]$m.width;height=[int]$m.height;hz=[int]$m.frequency}};"
        script += "@{owner='@DNPMBHC';session_id=1;modes=$modes;native_test_120=[NativeModeTest]::Test($device,3024,1964,120);native_test_60=[NativeModeTest]::Test($device,3024,1964,60);display_changes_applied=0}|ConvertTo-Json -Depth 4 -Compress"
        result, exit_code = execute_known_script(identifier, script)
        result.update(root_exit_code=exit_code, actual_session_one_verified=True)
        bootstrap.clone.save(EVIDENCE / "guest-supported-mode-inspection.json", result)
        print(json.dumps({"owner":"@DNPMBHC", "native_test_120":result["native_test_120"], "native_test_60":result["native_test_60"], "mode_count":len(result["modes"]), "display_changes_applied":0}))
        return 0
    except Exception as error:
        print(json.dumps({"owner":"@DNPMBHC", "error_code":str(error) if isinstance(error,RuntimeError) else type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

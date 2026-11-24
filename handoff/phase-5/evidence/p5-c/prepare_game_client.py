#!/usr/bin/env python3
"""Transfer and independently verify the unchanged official installer on the owned clone. Owner: @DNPMBHC."""
import importlib.util
import json
import subprocess
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("official_client_bootstrap", EVIDENCE / "bootstrap_guest_clone.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
EXPECTED_SHA = "686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e"
EXPECTED_SIZE = 491792264


def main():
    try:
        _, identifier = bootstrap.runtime.authorize()
        bootstrap.start_hidden(identifier)
        preflight = bootstrap.preflight(identifier)
        if not preflight["driver_ready"]: raise RuntimeError("actual_whql_driver_required")
        files = [p for p in bootstrap.runtime.ROOT.glob("*.exe")
                 if p.stat().st_size == EXPECTED_SIZE and bootstrap.clone.digest(p) == EXPECTED_SHA]
        if len(files) != 1: raise RuntimeError("official_installer_not_unique")
        space = bootstrap.powershell(identifier, "@{free_bytes=(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\").FreeSpace}")
        if space["free_bytes"] < EXPECTED_SIZE + 1073741824: raise RuntimeError("guest_installer_space_insufficient")
        target = r"C:\guest-shell-lab\official-installer.exe"
        print(json.dumps({"owner": "@DNPMBHC", "stage": "verified_installer_transfer_to_owned_clone"}), flush=True)
        with files[0].open("rb") as stream:
            result = subprocess.run([str(bootstrap.clone.controller()), "file", "push", "--hide", identifier, target],
                                    stdin=stream, capture_output=True, timeout=600)
        transfer = {"owner": "@DNPMBHC", "returncode": result.returncode,
                    "stderr_sha256": __import__("hashlib").sha256(result.stderr).hexdigest(),
                    "stdout_bytes": len(result.stdout), "stderr_bytes": len(result.stderr),
                    "owned_state_after_transfer": bootstrap.clone.command([str(bootstrap.clone.controller()), "status", identifier]).decode().strip()}
        bootstrap.clone.save(EVIDENCE / "official-installer-transfer.json", transfer)
        if result.returncode: raise RuntimeError("owned_installer_transfer_failed")
        report = bootstrap.powershell(identifier, r"""
$p='C:\guest-shell-lab\official-installer.exe';$sig=Get-AuthenticodeSignature -LiteralPath $p
@{owner='@DNPMBHC';sha256=(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant();
 size_bytes=(Get-Item -LiteralPath $p).Length;signature_status=[string]$sig.Status;
 version=(Get-Item -LiteralPath $p).VersionInfo.FileVersion;signature_type=[string]$sig.SignatureType}
""")
        report["verified"] = report["sha256"] == EXPECTED_SHA and report["size_bytes"] == EXPECTED_SIZE and report["signature_status"] == "Valid"
        report.update(primary_vm_control_actions=0, installer_started=False, human_login_completed=False)
        bootstrap.clone.save(EVIDENCE / "official-installer-own-guest-trust.json", report)
        if not report["verified"]: raise RuntimeError("official_guest_signature_verification_failed")
        print(json.dumps({"owner":"@DNPMBHC", "official_installer_guest_verified":True, "installer_started":False}))
        return 0
    except Exception as error:
        print(json.dumps({"owner":"@DNPMBHC", "error_code":str(error) if isinstance(error,RuntimeError) else type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

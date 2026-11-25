#!/usr/bin/env python3
"""Inspect only signed Settings-owned scale popup relationships. Owner: @DNPMBHC."""
import importlib.util
import json
import subprocess
from pathlib import Path
EVIDENCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("owned_topology_tools",EVIDENCE/"inspect_guest_display_modes.py")
inspection=importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspection)

def main():
    try:
        _,identifier=inspection.bootstrap.runtime.authorize()
        inspection.bootstrap.start_hidden(identifier)
        target=r"C:\guest-shell-lab\dpi-topology-probe.ps1"
        with (EVIDENCE/"dpi-topology-probe.ps1").open("rb") as stream:
            result=subprocess.run([str(inspection.bootstrap.clone.controller()),"file","push","--hide",identifier,target],stdin=stream,capture_output=True,timeout=60)
        if result.returncode: raise RuntimeError("topology_script_transfer_failed")
        source=r"""& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File 'C:\guest-shell-lab\dpi-topology-probe.ps1' -Mode Topology -ScaleAutomationId 'SystemSettings_Display_Scaling_ItemSizeOverride_ComboBox';exit $LASTEXITCODE"""
        report,code=inspection.execute_known_script(identifier,source)
        report.update(root_exit_code=code,actual_session_one_verified=True,display_changes_applied=0)
        inspection.bootstrap.clone.save(EVIDENCE/"guest-dpi-topology.json",report)
        print(json.dumps({"owner":"@DNPMBHC","passed":report.get("succeeded"),"topology":report.get("topology",[])}))
        return 0
    except Exception as error:
        print(json.dumps({"owner":"@DNPMBHC","error_code":str(error) if isinstance(error,RuntimeError) else type(error).__name__}))
        return 1
if __name__=="__main__": raise SystemExit(main())

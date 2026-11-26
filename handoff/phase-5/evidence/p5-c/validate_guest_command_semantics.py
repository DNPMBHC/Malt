#!/usr/bin/env python3
"""Read-only native PowerShell argument semantics; no display or target changes. Owner: @DNPMBHC."""
import importlib.util
import json
from pathlib import Path
EVIDENCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("owned_bridge_semantics",EVIDENCE/"bootstrap_guest_clone.py")
bootstrap=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
def main():
    try:
        _,identifier=bootstrap.runtime.authorize()
        source=r"""
function Test-BridgeTarget {param($operation,$request);@{operation=$operation;request=$request}|ConvertTo-Json -Compress}
$values=@('Test-BridgeTarget','status','00000000-0000-0000-0000-000000000001')
$value=& {$result=& $values[0] $values[1] $values[2]|ConvertFrom-Json;$result}
@{owner='@DNPMBHC';array_count=$values.Count;operation_matches=($value.operation -eq 'status');request_matches=($value.request -eq $values[2]);ui_changes=0}
"""
        report=bootstrap.powershell(identifier,source)
        report['passed']=report.get('operation_matches') is True and report.get('request_matches') is True and report.get('array_count')==3
        bootstrap.clone.save(EVIDENCE/'guest-command-bridge-semantics.json',report)
        print(json.dumps(report))
        return 0 if report['passed'] else 1
    except Exception as error:
        report={'owner':'@DNPMBHC','passed':False,'error_code':str(error) if isinstance(error,RuntimeError) else type(error).__name__,'ui_changes':0}
        bootstrap.clone.save(EVIDENCE/'guest-command-bridge-semantics.json',report)
        print(json.dumps(report));return 1
if __name__=='__main__':raise SystemExit(main())

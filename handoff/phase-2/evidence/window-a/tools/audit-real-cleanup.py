#!/usr/bin/env python3
"""Bind current-run acceptance and cleanup evidence without private identities."""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import base64
import importlib.util
import json
import re
import subprocess
import time
import uuid

EXPECTED_CASES = {
    'success': ('succeeded', 0), 'hostError': ('failed', 22),
    'overflow': ('failed', 22), 'timeout': ('timedOut', 20),
    'cancel': ('cancelled', 21),
}
LABEL_PATTERN = r'[a-z0-9-]{1,48}'
RUN_ID_PATTERN = r'run-[a-f0-9]{32}'

def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Evidence timestamp is missing.')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Evidence timestamp must include its timezone.')
    return parsed.astimezone(timezone.utc)

def validate_run_evidence(active, gate, compute, now=None):
    now = datetime.now(timezone.utc) if now is None else now
    if not all(isinstance(value, dict) for value in (active, gate, compute)):
        raise ValueError('Run evidence must contain objects.')
    label, run_id = active.get('label'), active.get('runID')
    if (active.get('schemaVersion') != 1 or not isinstance(label, str)
            or not re.fullmatch(LABEL_PATTERN, label) or not isinstance(run_id, str)
            or not re.fullmatch(RUN_ID_PATTERN, run_id)
            or active.get('filter') != 'UTMInteractiveRealTests'):
        raise ValueError('The active run is not a full real acceptance invocation.')
    started = timestamp(active.get('capturedAt'))
    gated = timestamp(gate.get('capturedAt'))
    computed = timestamp(compute.get('capturedAt'))
    if not started <= computed <= gated <= now + timedelta(seconds=5):
        raise ValueError('Run evidence is stale or its timestamps are inconsistent.')
    counts = gate.get('counts')
    if (gate.get('schemaVersion') != 1 or gate.get('label') != label
            or gate.get('filter') != active['filter'] or gate.get('realRunID') != run_id
            or gate.get('runStartedAt') != active['capturedAt']
            or type(gate.get('exitCode')) is not int or gate['exitCode'] != 0
            or gate.get('guestEnabled') is not True or gate.get('lockUnchanged') is not True
            or not isinstance(counts, dict)
            or any(type(counts.get(key)) is not int or counts[key] != expected
                   for key, expected in (('executed', 7), ('skipped', 0), ('failures', 0)))):
        raise ValueError('The active run lacks a complete successful real acceptance gate.')
    if (compute.get('schemaVersion') != 1 or compute.get('realRunID') != run_id
            or compute.get('scope') != 'explicitComputeInterfaceOnly'
            or compute.get('transparentPEMigration') is not False):
        raise ValueError('Compute evidence is not bound to this explicit-interface run.')
    cases = compute.get('cases')
    if (not isinstance(cases, list) or len(cases) != len(EXPECTED_CASES)
            or not all(isinstance(case, dict) for case in cases)):
        raise ValueError('The current run lacks all five compute cases.')
    names = [case.get('case') for case in cases]
    if not all(isinstance(name, str) for name in names) or set(names) != set(EXPECTED_CASES):
        raise ValueError('Compute case identities must be unique and complete.')
    for case in cases:
        expected_status, expected_exit = EXPECTED_CASES[case['case']]
        trace = case.get('hostTrace')
        if (case.get('status') != expected_status or type(case.get('exitCode')) is not int
                or case['exitCode'] != expected_exit
                or case.get('guestTerminalConfirmed') is not True
                or type(case.get('guestActiveProcessCount')) is not int
                or case['guestActiveProcessCount'] != 0
                or case.get('hostCleanupConfirmed') is not True
                or not isinstance(trace, dict) or trace.get('hasActiveConnection') is not False
                or trace.get('hasActiveComputation') is not False):
            raise ValueError('A current compute case lacks terminal or cleanup confirmation.')
    return {
        'label': label, 'realRunID': run_id, 'realAcceptanceGateConfirmed': True,
        'uniqueComputeCasesConfirmed': True, 'computeCaseCount': len(cases),
        'guestCaseJobTerminalConfirmed': True, 'guestCaseJobActiveProcessCountZeroConfirmed': True,
        'hostComputeServicesClean': True,
    }

def load_control(evidence):
    spec = importlib.util.spec_from_file_location('leased_control', evidence / 'tools/run-real-tests.py')
    control = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control)
    return control

def inventory_script(challenge):
    if not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', challenge):
        raise ValueError('Cleanup inventory challenge is invalid.')
    # Fixed directory inventory only; this is independent of per-case Job evidence.
    return r'''$ErrorActionPreference = 'Stop'
$prefix = 'C:\demo-app\window-a\'
$live = @(Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
})
[pscustomobject]@{
  challenge = 'CHALLENGE'
  guestOwnedDirectoryLiveProcessCount = $live.Count
  guestOwnedDirectoryProcessInventoryClear = ($live.Count -eq 0)
} | ConvertTo-Json -Compress
'''.replace('CHALLENGE', challenge)

def guest_inventory(control, vm_id):
    challenge = str(uuid.uuid4())
    script = inventory_script(challenge)
    pid = control.apple(control.EXECUTE,
                        [vm_id, base64.b64encode(script.encode('utf-16-le')).decode()])
    if not pid.isdecimal():
        raise ValueError('Cleanup inventory process identity is invalid.')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        fields = control.apple(control.RESULT, [vm_id, pid],
                               timeout=max(0.1, min(5, deadline - time.monotonic()))).split('\n', 3)
        if fields[0] == '1':
            if len(fields) < 3 or fields[1] != '0':
                raise ValueError('Cleanup inventory process failed.')
            try:
                raw = base64.b64decode(fields[2], validate=True).decode('utf-8')
            except (ValueError, UnicodeError):
                raw = fields[3] if len(fields) > 3 else fields[2]
            try:
                candidate = json.loads(raw)
            except ValueError:
                candidate = {}
            if isinstance(candidate, dict) and candidate.get('challenge') == challenge:
                count = candidate.get('guestOwnedDirectoryLiveProcessCount')
                clear = candidate.get('guestOwnedDirectoryProcessInventoryClear')
                if type(count) is not int or count < 0 or type(clear) is not bool or clear != (count == 0):
                    raise ValueError('Cleanup inventory count is invalid.')
                return {'guestOwnedDirectoryLiveProcessCount': count,
                        'guestOwnedDirectoryProcessInventoryClear': clear,
                        'guestInventoryRequestBound': True}
        time.sleep(0.1)
    raise ValueError('Cleanup inventory was not bound to this audit request.')

def host_test_process_count(evidence):
    processes = subprocess.check_output(['ps', '-axww', '-o', 'command='], text=True).splitlines()
    return sum(str(evidence / 'build/scratch') in process and '.xctest' in process
               for process in processes)

def cleanup_accepted(report):
    return (report.get('realAcceptanceGateConfirmed') is True
            and report.get('uniqueComputeCasesConfirmed') is True
            and report.get('guestCaseJobTerminalConfirmed') is True
            and report.get('guestCaseJobActiveProcessCountZeroConfirmed') is True
            and report.get('guestInventoryRequestBound') is True
            and report.get('guestOwnedDirectoryProcessInventoryClear') is True
            and type(report.get('guestOwnedDirectoryLiveProcessCount')) is int
            and report['guestOwnedDirectoryLiveProcessCount'] == 0
            and type(report.get('hostProbeTestProcesses')) is int
            and report['hostProbeTestProcesses'] == 0
            and report.get('hostComputeServicesClean') is True)

def main():
    root = next(p for p in [Path.cwd(), *Path.cwd().parents]
                if (p / 'handoff/phase-2/evidence/window-a').is_dir())
    evidence = root / 'handoff/phase-2/evidence/window-a'
    report = {'schemaVersion': 1, 'capturedAt': datetime.now(timezone.utc).isoformat(),
              'scope': 'selfOwnedWindowAProbesAndComputeServices', 'accepted': False}
    stage = 'runEvidence'
    try:
        active = json.loads((evidence / 'active-real-run.json').read_text())
        label = active.get('label') if isinstance(active, dict) else None
        if not isinstance(label, str) or not re.fullmatch(LABEL_PATTERN, label):
            raise ValueError('The active evidence label is invalid.')
        gate = json.loads((evidence / 'build' / (label + '.json')).read_text())
        compute = json.loads((evidence / 'real-m1.json').read_text())
        report.update(validate_run_evidence(active, gate, compute))
        control = load_control(evidence)
        stage = 'guestIdentity'
        vm_id = control.resolve_current_vm(evidence)
        report['currentGuestIdentityArchitectureStateVerified'] = True
        stage = 'guestInventory'
        report.update(guest_inventory(control, vm_id))
        stage = 'hostInventory'
        report['hostProbeTestProcesses'] = host_test_process_count(evidence)
        report['accepted'] = cleanup_accepted(report)
    except Exception:
        report['failureStage'] = stage
        report['note'] = 'Current-run cleanup audit failed safely; private diagnostics were not exported.'
    report['capturedAt'] = datetime.now(timezone.utc).isoformat()
    temporary = evidence / 'real-cleanup-audit.json.pending'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(evidence / 'real-cleanup-audit.json')
    print(json.dumps(report))
    return 0 if report['accepted'] else 1

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit('Cleanup audit failed safely; private diagnostics were not exported.')

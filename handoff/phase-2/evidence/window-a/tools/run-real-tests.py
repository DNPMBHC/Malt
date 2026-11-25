#!/usr/bin/env python3
"""Run leased Guest acceptance with transient identity and route verification."""
from pathlib import Path
from datetime import datetime, timezone
import argparse, subprocess, os, re, json, time, base64, ipaddress, uuid

LABEL_PATTERN = r'[a-z0-9-]{1,48}'
VM_ID_PATTERN = r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}'
RUN_ID_PATTERN = r'run-[a-f0-9]{32}'

INSPECT = r'''on run argv
 tell application id "com.utmapp.UTM"
  set vm to virtual machine id (item 1 of argv)
  set vmBackend to backend of vm as text
  set vmConfig to configuration of vm
  set vmArchitecture to architecture of vmConfig as text
  return (id of vm as text) & linefeed & vmBackend & linefeed & (status of vm as text) & linefeed & vmArchitecture
 end tell
end run'''
EXECUTE = r'''on run argv
 tell application id "com.utmapp.UTM"
  set vm to virtual machine id (item 1 of argv)
  set p to execute of vm at "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" with arguments {"-NoProfile", "-NonInteractive", "-EncodedCommand", item 2 of argv} with output capturing
  return id of p as text
 end tell
end run'''
RESULT = r'''on run argv
 tell application id "com.utmapp.UTM"
  set vm to virtual machine id (item 1 of argv)
  set p to guest process id ((item 2 of argv) as integer) of vm
  set r to get result of p
  if exited of r then
   return "1" & linefeed & (exit code of r as text) & linefeed & (output data of r as text) & linefeed & (output text of r as text)
  end if
  return "0"
 end tell
end run'''
NETWORK = r'''$ErrorActionPreference = 'Stop'; $c = @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | ForEach-Object { [pscustomobject]@{ address = $_.IPv4Address.IPAddress; prefix = $_.IPv4Address.PrefixLength; gateway = $_.IPv4DefaultGateway.NextHop } }); ConvertTo-Json -InputObject $c -Compress'''

def apple(script, args, timeout=10):
    result = subprocess.run(['osascript', '-e', script, '--', *args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Current Guest automation preflight failed.')
    return result.stdout.strip()

def utc_now():
    return datetime.now(timezone.utc).isoformat()

def workspace_evidence():
    root = next(p for p in [Path.cwd(), *Path.cwd().parents]
                if (p / 'handoff/phase-2/evidence/window-a').is_dir())
    return root, root / 'handoff/phase-2/evidence/window-a'

def parse_vm_inspection(vm_id, response):
    fields = response.splitlines()
    if (not re.fullmatch(VM_ID_PATTERN, vm_id) or len(fields) != 4
            or fields[0].lower() != vm_id.lower() or fields[1].lower() != 'qemu'
            or fields[2].lower() != 'started'
            or fields[3].lower() not in ('arm64', 'aarch64')):
        raise ValueError('Current Guest identity, architecture or running state is not verified.')

def resolve_current_vm(evidence, environ=None):
    environ = os.environ if environ is None else environ
    vm_id = environ.get('DEMO_REAL_GUEST_VM_ID')
    if not vm_id:
        match = re.search(VM_ID_PATTERN, (evidence / 'summary.md').read_text())
        if not match:
            raise ValueError('Expected Guest identity is unavailable.')
        vm_id = match.group(0)
    if not isinstance(vm_id, str) or not re.fullmatch(VM_ID_PATTERN, vm_id):
        raise ValueError('Expected Guest identity is invalid.')
    parse_vm_inspection(vm_id, apple(INSPECT, [vm_id]))
    return vm_id

def write_json(path, value):
    temporary = path.with_name(path.name + '.pending')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)

def begin_real_run(evidence, label, test_filter):
    if not re.fullmatch(LABEL_PATTERN, label):
        raise ValueError('Evidence label is invalid.')
    active = {'schemaVersion': 1, 'label': label, 'runID': 'run-' + uuid.uuid4().hex,
              'capturedAt': utc_now(), 'filter': test_filter}
    write_json(evidence / 'active-real-run.json', active)
    # The wrapper replaces this label's gate. Remove the previous gate first so
    # an interrupted invocation cannot relabel a stale successful result.
    (evidence / 'build' / (label + '.json')).unlink(missing_ok=True)
    (evidence / 'real-cleanup-audit.json').unlink(missing_ok=True)
    return active

def bind_test_gate(evidence, active, started_ns, exit_code):
    gate_path = evidence / 'build' / (active['label'] + '.json')
    if gate_path.stat().st_mtime_ns < started_ns:
        raise ValueError('The current run did not produce a fresh test gate.')
    gate = json.loads(gate_path.read_text())
    if (gate.get('schemaVersion') != 1 or gate.get('label') != active['label']
            or gate.get('filter') != active['filter'] or gate.get('exitCode') != exit_code
            or gate.get('guestEnabled') is not True):
        raise ValueError('The current test gate does not match this invocation.')
    gate.update({'realRunID': active['runID'], 'capturedAt': utc_now(),
                 'runStartedAt': active['capturedAt']})
    write_json(gate_path, gate)

def routes(vm_id):
    pid = apple(EXECUTE, [vm_id, base64.b64encode(NETWORK.encode('utf-16-le')).decode()])
    if not pid.isdecimal(): raise RuntimeError('Guest route probe identity is invalid.')
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        fields = apple(RESULT, [vm_id, pid], timeout=max(0.1, min(10, deadline-time.monotonic()))).split('\n', 3)
        if fields[0] == '1':
            if len(fields) < 3 or fields[1] != '0': raise RuntimeError('Guest route probe failed.')
            try:
                raw = base64.b64decode(fields[2], validate=True).decode('utf-8')
            except (ValueError, UnicodeError):
                raw = fields[3] if len(fields) > 3 else fields[2]
            value = json.loads(raw)
            return value if isinstance(value, list) else [value]
        time.sleep(0.1)
    raise RuntimeError('Guest route probe exceeded its deadline.')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--lease-released', action='store_true', required=True)
    parser.add_argument('--filter', default='UTMInteractiveRealTests')
    parser.add_argument('--label', default='real-guest')
    args=parser.parse_args()
    root, evidence = workspace_evidence()
    active = begin_real_run(evidence, args.label, args.filter)
    vm_id = resolve_current_vm(evidence)
    guest_routes=routes(vm_id)
    network=subprocess.check_output(['ifconfig'],text=True)
    addresses=[]
    for bridge in re.split(r'\n(?=\S)', network):
        if bridge.startswith('bridge'):
            addresses.extend(re.findall(r'\binet (\d+\.\d+\.\d+\.\d+) ', bridge))
    candidates=set()
    for route in guest_routes:
        subnet=ipaddress.ip_network(str(route['address'])+'/'+str(route['prefix']),strict=False)
        candidates.update(a for a in addresses if ipaddress.ip_address(a) in subnet and a!=route['address'])
    address=os.environ.get('DEMO_REAL_GUEST_BIND_ADDRESS')
    if address:
        if address not in candidates: raise RuntimeError('The selected host address does not match the current Guest subnet.')
    elif len(candidates)==1:
        address=candidates.pop()
    else:
        raise RuntimeError('A unique host bridge matching the current Guest route is required.')
    guest_host=os.environ.get('DEMO_REAL_GUEST_HOST_ADDRESS',address)
    env=os.environ.copy()
    env.update({'DEMO_REAL_GUEST_ENABLED':'1','DEMO_REAL_GUEST_VM_ID':vm_id,
                'DEMO_WINDOW_A_EVIDENCE':str(evidence),'DEMO_REAL_GUEST_BIND_ADDRESS':address,
                'DEMO_REAL_GUEST_HOST_ADDRESS':guest_host,'DEMO_REAL_RUN_ID':active['runID']})
    (evidence/'real-environment-preflight.json').write_text(json.dumps({
        'schemaVersion':1,'realRunID':active['runID'],'capturedAt':utc_now(),
        'vmIdentityMatched':True,'guestArchitecture':'arm64','guestState':'started',
        'hostBridgeMatchesCurrentGuestSubnet':True,'tcpRoundtripVerified':False,
        'note':'The authenticated real compute roundtrip must verify connectivity.'},indent=2)+'\n')
    print('Current Guest identity and route matched; validating the real authenticated roundtrip.',flush=True)
    started_ns = time.time_ns()
    code = subprocess.call(['python3',str(evidence/'tools/run-swift-tests.py'),
                            '--filter',args.filter,'--label',args.label],cwd=root,env=env)
    bind_test_gate(evidence, active, started_ns, code)
    return code

if __name__=='__main__':
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit('Real Guest preflight failed safely; private diagnostics were not exported.')

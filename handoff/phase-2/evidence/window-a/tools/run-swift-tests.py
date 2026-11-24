#!/usr/bin/env python3
"""Run the assigned tests with build outputs confined to this window."""
from pathlib import Path
import argparse, subprocess, os, re, json, hashlib
parser = argparse.ArgumentParser()
parser.add_argument('--filter', default='UTM')
parser.add_argument('--label', default='unit')
args = parser.parse_args()
root = next(p for p in [Path.cwd(), *Path.cwd().parents] if (p / 'handoff/phase-2/evidence/window-a').is_dir())
source = next(Path(x) for x in subprocess.check_output(['rg', '--files', '-g', 'UTMWindowsGuestProvider.swift'], cwd=root, text=True).splitlines())
package = root / str(source).split('/Sources/')[0]
build = root / 'handoff/phase-2/evidence/window-a/build'
for name in ['tmp', 'scratch', 'cache', 'config', 'security']: (build / name).mkdir(exist_ok=True)
lock = package / 'Package.resolved'
before = hashlib.sha256(lock.read_bytes()).hexdigest()
cmd = ['swift', 'test', '--package-path', str(package), '--scratch-path', str(build/'scratch'),
       '--cache-path', str(build/'cache'), '--config-path', str(build/'config'),
       '--security-path', str(build/'security'), '--disable-automatic-resolution']
if args.filter: cmd += ['--filter', args.filter]
env = os.environ.copy()
env['TMPDIR'] = os.path.relpath(build/'tmp', package) + '/'
proc = subprocess.Popen(cmd, cwd=package, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
lines = []
with (build / (args.label+'.log')).open('w') as out:
    for line in proc.stdout:
        for key in ['DEMO_REAL_GUEST_BIND_ADDRESS', 'DEMO_REAL_GUEST_HOST_ADDRESS', 'DEMO_REAL_GUEST_VM_ID', 'DEMO_WINDOW_A_EVIDENCE']:
            if env.get(key): line = line.replace(env[key], '<TRANSIENT_VALUE>')
        line = line.replace(str(root), '<WORKSPACE>')
        line = re.sub(re.escape(source.parts[0]), 'module-b', line, flags=re.I)
        line = re.sub(r'/Users/[^\s\"\'<>]*', '<LOCAL_PATH>', line)
        line = re.sub(r'/Volumes/[^\s\"\'<>]*', '<LOCAL_PATH>', line)
        line = line.replace('SemanticVersion', 'dependency-a')
        line = re.sub(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', '<REQUEST_ID>', line)
        lines.append(line)
        out.write(line)
        out.flush()
        if any(t in line for t in ['error:', 'warning:', 'failed', 'skipped', 'Executed', 'Build complete']): print(line, end='', flush=True)
code = proc.wait()
summary = {'schemaVersion':1,'label':args.label,'filter':args.filter,'exitCode':code,
           'lockUnchanged':before==hashlib.sha256(lock.read_bytes()).hexdigest(),
           'guestEnabled':env.get('DEMO_REAL_GUEST_ENABLED')=='1'}
counts = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', ''.join(lines))
if counts:
    count, skipped, failures = counts[-1]
    summary['counts'] = {'executed':int(count),'skipped':int(skipped or 0),'failures':int(failures)}
(build/(args.label+'.json')).write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary), flush=True)
raise SystemExit(code)

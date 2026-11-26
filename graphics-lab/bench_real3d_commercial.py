#!/usr/bin/env python3
"""Official installer lifecycle in an owned external Wine Bottle. @DNPMBHC.

This helper launches software and records lifecycle evidence. It does not interact
with agreements, account forms, identity verification, or CAPTCHA interfaces.
The caller must keep the desktop visible and hand those interfaces to the user.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import bench_real3d_capture as capture
import bench_real3d_support as support
import wine_kosmickrisp_benchmark as wine


def prepare(backend: str) -> tuple[dict, Path, dict]:
    if backend not in ('dxmt', 'd3dmetal'):
        raise ValueError('Explicit permitted Wine graphics backend required')
    runtime = support.runtime_dir()
    owner = json.loads((runtime / 'ownership.json').read_text())
    if owner.get('phase') != 'p5-a':
        raise RuntimeError('External runtime ownership mismatch')
    work = runtime / ('commercial-wine-' + backend)
    work.mkdir(exist_ok=False)
    support.write_json(work / 'ownership.json', {'owner':'@DNPMBHC','phase':'p5-a'})
    components = wine.resolve_four_way_components(wine.DEFAULT_ENGINE_ROOT)
    prefix = wine._prepare_prefix(components, backend, work)
    # Restrict default host filesystem mappings inside this disposable prefix.
    user_root = prefix / 'drive_c/users'
    for directory, subdirs, filenames in os.walk(user_root, followlinks=False):
        for name in subdirs + filenames:
            entry = Path(directory) / name
            if entry.is_symlink():
                entry.unlink()
                entry.mkdir()
    devices = prefix / 'dosdevices'
    for entry in devices.iterdir():
        if entry.is_symlink() and entry.name.lower() != 'c:':
            entry.unlink()
    data = work / 'data'
    data.mkdir()
    (devices / 'r:').symlink_to(data, target_is_directory=True)
    tools = prefix / 'drive_c/p5a-tools'
    tools.mkdir()
    installer = runtime / 'installer-x.exe'
    expected = json.loads((support.EVIDENCE / 'official-installer-guest-trust.json').read_text())
    if expected['signature_status'] != 'Valid' or support.sha256(installer) != expected['sha256']:
        raise RuntimeError('Installer hash is not bound to the Windows-verified artifact')
    shutil.copy2(installer, tools / 'installer-x.exe')
    env = wine.build_backend_env(components, backend, prefix, work, metalfx_preset='off')
    env['WINEDEBUG'] = '-all,+loaddll,+seh'
    return components, work, env


def run(backend: str) -> int:
    components, work, env = prepare(backend)
    stem = 'wine-commercial-' + backend
    destination = capture.real_run_dir()
    record = {'owner':'@DNPMBHC','backend':backend,'started_at_utc':support.utc(),
              'installer_sha256':support.sha256(work / 'prefix/drive_c/p5a-tools/installer-x.exe'),
              'desktop_visibility':'caller must verify separately',
              'agreements_or_authentication_automated':False,
              'host_user_directory_links_removed':True,'root_drive_mapping_removed':True,
              'native_exit_code':None,'gui_rendering':'not yet observed',
              'kernel_protection_load':'not tested','game_start':'not tested'}
    with (work / 'server-private.log').open('wb') as server_log, \
         (work / 'installer-private.stdout.log').open('wb') as stdout, \
         (work / 'installer-private.stderr.log').open('wb') as stderr:
        server = subprocess.Popen([str(components['wineserver_bin']),'-f','-p'],env=env,
                                  stdout=server_log,stderr=server_log)
        proc = subprocess.Popen([str(components['wine_bin']),r'C:\p5a-tools\installer-x.exe'],
                                env=env,stdout=stdout,stderr=stderr)
        support.write_json(work / 'process-state.json',{'installer_pid':proc.pid,'server_pid':server.pid})
        support.write_json(destination / (stem + '-lifecycle.json'),record)
        print('Official installer process launched in owned Wine Bottle',flush=True)
        code = proc.wait()
        record.update({'installer_process_ended_at_utc':support.utc(),'native_exit_code':code,
                       'limitation':'Installer exit does not establish child launcher or game completion.'})
        support.write_json(destination / (stem + '-lifecycle.json'),record)
        print('Official Wine installer native exit '+str(code),flush=True)
    return code


def export_logs(backend: str) -> None:
    work = support.runtime_dir() / ('commercial-wine-' + backend)
    owner = json.loads((work / 'ownership.json').read_text())
    if owner.get('phase') != 'p5-a':
        raise RuntimeError('Bottle ownership mismatch')
    private_markers = re.compile(r'password|passwd|token|cookie|openid|identity|phone|email|username|user.?id|login|ticket|authorization|credential|session|\baccount\b|\buin\b|\buid\b|实名|验证码',re.I)
    for name in ('server-private.log','installer-private.stdout.log','installer-private.stderr.log'):
        original = (work / name).read_text(errors='replace')
        safe = '\n'.join('<private-authentication-line-omitted>' if private_markers.search(line)
                         else support.redact(line) for line in original.splitlines())
        (capture.real_run_dir() / ('wine-commercial-' + backend + '-' + name.replace('-private',''))).write_text(safe+'\n')
    print('Redacted Wine lifecycle logs exported')


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('action',choices=('run','export'))
    parser.add_argument('--backend',choices=('dxmt','d3dmetal'),default='dxmt')
    args = parser.parse_args(argv)
    if args.action == 'run':return run(args.backend)
    export_logs(args.backend)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

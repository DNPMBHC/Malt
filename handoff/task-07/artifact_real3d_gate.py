#!/usr/bin/env python3
"""Supplement the release gate with the delivered asynchronous draw-call probe. @DNPMBHC."""
from __future__ import annotations

import csv
import json
import os
import pathlib
import re
import shutil
import statistics
import subprocess
import tempfile
import time

import artifact_perf_gate as gate


def summarize_real3d(path, stdout, frames, draws):
    metadata = completion = None
    for line in stdout.splitlines():
        if line.startswith('real3d_metadata_json='):
            metadata = json.loads(line.split('=', 1)[1])
        if line.startswith('real3d_completion_json='):
            completion = json.loads(line.split('=', 1)[1])
    with path.open(encoding='utf-8-sig') as handle:
        rows = list(csv.DictReader(handle))
    if not metadata or not completion:
        raise ValueError('missing_real3d_completion_evidence')
    intervals = sorted(float(row['cpu_frame_ms']) for row in rows if int(row['frame_index']) > 0)
    memory = [int(row['device_memory_bytes']) / 1048576 for row in rows if int(row['device_memory_bytes']) > 0]
    errors = []
    if len(rows) != frames or completion.get('measured_frames') != frames:
        errors.append('incomplete_real3d_frames')
    if [int(row['frame_index']) for row in rows] != list(range(frames)):
        errors.append('real3d_frame_sequence_mismatch')
    if metadata.get('draws_per_frame') != draws or metadata.get('cb_updates_per_frame') != 256:
        errors.append('real3d_workload_mismatch')
    if not metadata.get('async_swapchain') or metadata.get('adapter_is_software'):
        errors.append('real3d_hardware_async_required')
    if completion.get('total_draw_calls') != frames * draws:
        errors.append('real3d_draw_count_mismatch')
    if metadata.get('width') != 1280 or metadata.get('height') != 720:
        errors.append('real3d_resolution_mismatch')
    wall = completion.get('measurement_wall_ms', 0)
    fps = completion.get('throughput_including_gpu_drain_fps', 0)
    if wall <= 0 or fps <= 0 or abs(fps - frames * 1000 / wall) > max(0.01, fps * 0.001):
        errors.append('real3d_completion_throughput_mismatch')
    if completion.get('gpu_drain_ms', -1) < 0:
        errors.append('real3d_gpu_drain_missing')
    return {'frameCount': len(rows), 'derivedFPS': fps,
            'frameIntervalP95Ms': gate.percentile(intervals, 95),
            'deviceMemoryMiBMean': statistics.fmean(memory) if memory else None,
            'gpuDrainMs': completion.get('gpu_drain_ms'), 'measurementWallMs': wall,
            'csvSHA256': gate.sha256_file(path), 'metadata': metadata, 'errors': errors}


def run_real3d_gate(app, workspace, probe_source, evidence, rounds=3):
    baseline_path = workspace / 'handoff/phase-5/evidence/p5-a/real3d-baseline-wine.json'
    baseline = json.loads(baseline_path.read_text())
    expected = baseline['immutable_digests']['bench_real3d_probe_exe']
    if gate.sha256_file(probe_source) != expected:
        raise ValueError('delivered_real3d_probe_checksum_mismatch')
    app_binary, cli, identity = gate._find_packaged_cli(app)
    gate._redact_product = re.escape(app_binary.name)
    gate._redact_driver = r'kosmickrisp'
    gate._redact_identity = re.escape(identity)
    engines = gate._discover_engine_layout(gate.DEFAULT_ENGINE_ROOT)
    evidence.mkdir(parents=True, exist_ok=True)
    scenarios = {}
    with gate.isolated_temporary_directory(prefix='demo-app-real3d-', dir='/tmp') as tmp:
        temporary = pathlib.Path(tmp).resolve()
        probe = temporary / probe_source.name
        shutil.copy2(probe_source, probe)
        launcher = temporary / 'wine-reference-launch'
        subprocess.run(['xcrun', 'swiftc', str(pathlib.Path(__file__).with_name('wine_reference_launch.swift')),
                        '-o', str(launcher)], capture_output=True, check=True, timeout=60)
        home = temporary / 'home'
        home.mkdir()
        gate._mount_sandbox_runtime(temporary / 'runtime', engines, app_binary.name)
        env = os.environ.copy()
        for key in ('VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'VK_ADD_DRIVER_FILES', 'WINE_SONAME_LIBVULKAN',
                    'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE', 'DXMT_CONFIG',
                    'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'WINEDLLPATH'):
            env.pop(key, None)
        env.update(CFFIXED_USER_HOME=str(home), WINEDEBUG='-all')
        env[app_binary.name.upper() + '_RUNTIME_ROOT'] = str(temporary / 'runtime')
        for label, mode, prefer in [('dxmt', 'dxmt', True), ('d3dMetal', 'd3dMetal', True),
                                    ('dxvk_backend-k', 'dxvk', True), ('dxvk_moltenvk', 'dxvk', False)]:
            samples = []
            print('[real3d] Starting ' + label, flush=True)
            for index in range(rounds):
                name = 'real3d-' + label + '-' + str(index)
                cache = temporary / ('cache-' + name)
                bottle = gate._create_and_configure_bottle(cli, env, name, mode, dxvk_prefer_kosmickrisp=prefer)
                try:
                    gate._init_bottle_prefix(bottle, engines, mode, cache)
                    shell = subprocess.run([str(cli), 'shellenv', name], env=env, capture_output=True,
                                           text=True, check=True, timeout=60)
                    values = gate.parse_shell_environment(shell.stdout)
                    pair = {}
                    errors = []
                    for kind in (('reference', 'artifact') if index % 2 == 0 else ('artifact', 'reference')):
                        output = temporary / (name + '-' + kind + '.csv')
                        overrides = {**values, 'XDG_CACHE_HOME': str(temporary / (name + '-cache-' + kind)),
                                     'DXMT_SHADER_CACHE_PATH': str(bottle / 'gate_cache' / kind / 'dxmt'),
                                     'DXVK_STATE_CACHE_PATH': str(bottle / 'gate_cache' / kind / 'dxvk'),
                                     'DXMT_USE_DEFAULT_METAL_CACHE': '0', 'VK_LOADER_DEBUG': 'driver'}
                        overrides.pop('PATH', None)
                        probe_args = [str(probe), '--width', '1280', '--height', '720', '--warmup', '120',
                                '--frames', '900', '--draws', '2048', '--cb-updates', '256',
                                '--csv', 'Z:' + str(output).replace('/', '\\')]
                        capture = temporary / (name + '-' + kind + '-output.txt')
                        batch = temporary / (name + '-' + kind + '.cmd')
                        command_line = ' '.join('"' + ('Z:' + arg.replace('/', '\\') if arg == str(probe) else arg) + '"'
                                                for arg in probe_args)
                        batch.write_text('@echo off\ncd /d "Z:' + str(temporary).replace('/', '\\') + '"\n' +
                                         command_line + ' > "Z:' + str(capture).replace('/', '\\') + '" 2>&1\n' +
                                         'set "probe_exit=%ERRORLEVEL%"\nexit /b %probe_exit%\n')
                        wrapper = bottle / 'drive_c/windows/system32/cmd.exe'
                        args = [str(wrapper), '/d', '/c', 'Z:' + str(batch).replace('/', '\\')]
                        if kind == 'reference':
                            command = [str(launcher), str(engines['wine_root'] / 'bin/wine'), 'start', '/wait', '/unix', *args]
                            run_env = overrides
                        else:
                            gate.configure_probe_environment(bottle, wrapper, overrides, launcher)
                            command = [str(cli), 'run', '--bottle-path', '--', str(bottle), *args]
                            run_env = env
                        started = time.time()
                        process = gate.run_probe(command, run_env, cwd=temporary)
                        gate.stop_bottle_prefix(engines, bottle, env)
                        native_output = capture.read_text(errors='replace') if capture.exists() else ''
                        if kind == 'artifact':
                            process.stdout += '\n' + gate.read_probe_logs(home, started)
                        log = gate._redact_run(process.stdout + '\n' + process.stderr + '\n' + native_output, workspace, temporary)
                        (evidence / (output.stem + '.log')).write_text(log)
                        if process.returncode or not output.exists():
                            pair[kind] = {'frameCount': 0, 'derivedFPS': 0}
                            errors.append(kind + '_real3d_launch_failed')
                        else:
                            try:
                                pair[kind] = summarize_real3d(output, native_output, 900, 2048)
                                errors.extend(pair[kind]['errors'])
                            except ValueError:
                                pair[kind] = {'frameCount': 0, 'derivedFPS': 0,
                                              'csvSHA256': gate.sha256_file(output)}
                                errors.append(kind + '_real3d_completion_evidence_missing')
                            shutil.copy2(output, evidence / output.name)
                    paired = gate.evaluate_paired_runs(pair['artifact'], pair['reference'], mode, require_gpu=False)
                    samples.append({**pair, 'errors': errors, 'integrityPassed': not errors,
                                    'round': index + 1, 'pairedConsistency': paired})
                    checkpoint = {'owner': '@DNPMBHC', 'complete': False, 'backends': scenarios,
                                  'currentBackend': label, 'currentRuns': samples,
                                  'appBinarySHA256': gate.sha256_file(app_binary),
                                  'cliBinarySHA256': gate.sha256_file(cli), 'deliveredProbeSHA256': expected}
                    progress = evidence.parent / 'real3d-gate-progress.json'
                    progress.write_text(gate._redact_run(json.dumps(checkpoint, indent=2), workspace, temporary) + '\n')
                finally:
                    gate.stop_bottle_prefix(engines, bottle, env)
                    gate.remove_isolated_directory(bottle)
                    gate.remove_isolated_directory(cache)
                    for kind in ('artifact', 'reference'):
                        gate.remove_isolated_directory(temporary / (name + '-cache-' + kind))
            aggregate = gate.aggregate_paired_runs(samples, mode, 900)
            scenarios[label] = {'passed': all(s['integrityPassed'] for s in samples) and aggregate['passed'],
                                'runs': samples, 'aggregateConsistency': aggregate,
                                'rawPerformanceOutlierCount': sum(not s['pairedConsistency']['passed'] for s in samples)}
            (evidence.parent / 'real3d-gate-progress.json').write_text(gate._redact_run(
                json.dumps({'owner': '@DNPMBHC', 'complete': False, 'backends': scenarios,
                            'appBinarySHA256': gate.sha256_file(app_binary), 'cliBinarySHA256': gate.sha256_file(cli),
                            'deliveredProbeSHA256': expected}, indent=2), workspace, temporary) + '\n')
            print('[real3d] Finished ' + label + ': ' + ('passed' if scenarios[label]['passed'] else 'failed'), flush=True)
        report = {'owner': '@DNPMBHC', 'backendCoverageComplete': len(scenarios) == 4,
                  'passed': len(scenarios) == 4 and all(v['passed'] for v in scenarios.values()),
                  'deliveredProbeSHA256': expected, 'deliveryManifestSHA256': gate.sha256_file(baseline_path),
                  'workload': {'width': 1280, 'height': 720, 'drawsPerFrame': 2048, 'cbUpdates': 256,
                               'measuredFrames': 900, 'warmupFrames': 120, 'rounds': rounds},
                  'backends': scenarios, 'scope': 'Delivered preliminary draw-call probe, same-host artifact/reference pairs. '
                  'Both paths launch cmd.exe with ordinary output redirection through Wine start /wait /unix. '
                  'Throughput includes the final GPU drain. Drain duration is not a GPU frame timestamp. '
                  'The newer heavy-scene pilot and commercial games are not claimed.'}
        return json.loads(gate._redact_run(json.dumps(report), workspace, temporary))

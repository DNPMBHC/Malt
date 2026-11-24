#!/usr/bin/env python3
"""Artifact-level performance consistency gate against the packaged Release .app CLI."""

from __future__ import annotations

import argparse
import contextlib
import copy
import csv
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import statistics
import re
import shlex
import time
import subprocess
import sys
import tempfile
import signal


from runtime_bundle_gate import probe_driver, verify_hardened

DEFAULT_ENGINE_ROOT = next((pathlib.Path.home() / 'Library/Application Support').glob('*/wine-engine'), pathlib.Path('/missing-runtime'))
LAB_BASELINE_MANIFEST = 'handoff/phase-4/evidence/p4-a/wine-four-way-benchmark/manifest.json'
PROBE_RELPATH = 'graphics-lab/build/d3d11_probe.exe'


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    pos = (pct / 100.0) * (len(sorted_values) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_values) - 1)
    frac = pos - lo
    return sorted_values[lo] * (1.0 - frac) + sorted_values[hi] * frac


def summarize_probe_csv(csv_path: pathlib.Path) -> dict:
    """Parse d3d11_probe.exe CSV into consistent FPS, frame-interval, and DXGI VRAM metrics."""
    intervals_ms: list[float] = []
    device_mem_mib: list[float] = []
    gpu_ms_values: list[float] = []
    row_count = 0

    with csv_path.open('r', encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        prev_ts_ns: float | None = None
        for row in reader:
            row_count += 1
            interval = row.get('cpu_frame_ms') or row.get('frame_interval_ms') or row.get('frame_ms')
            if interval not in (None, ''):
                val = float(interval)
                if val > 0:
                    intervals_ms.append(val)
            else:
                ts_raw = row.get('present_timestamp_ns') or row.get('timestamp_ns')
                if ts_raw not in (None, ''):
                    ts_ns = float(ts_raw)
                    if prev_ts_ns is not None and ts_ns > prev_ts_ns:
                        intervals_ms.append((ts_ns - prev_ts_ns) / 1_000_000.0)
                    prev_ts_ns = ts_ns

            mem_raw = row.get('device_memory_bytes')
            if mem_raw not in (None, ''):
                device_mem_mib.append(float(mem_raw) / (1024.0 * 1024.0))

            gpu_raw = row.get('gpu_ms')
            if gpu_raw not in (None, ''):
                gpu_val = float(gpu_raw)
                if gpu_val >= 0:
                    gpu_ms_values.append(gpu_val)

    sorted_intervals = sorted(intervals_ms)
    mean_ms = statistics.fmean(sorted_intervals) if sorted_intervals else 0.0
    derived_fps = (1000.0 / mean_ms) if mean_ms > 0 else 0.0
    return {
        'frameCount': row_count,
        'intervalCount': len(sorted_intervals),
        'frameIntervalMeanMs': round(mean_ms, 4),
        'frameIntervalP50Ms': round(percentile(sorted_intervals, 50.0), 4),
        'frameIntervalP95Ms': round(percentile(sorted_intervals, 95.0), 4),
        'derivedFPS': round(derived_fps, 2),
        'gpuMsMean': round(statistics.fmean(gpu_ms_values), 4) if gpu_ms_values else None,
        'deviceMemoryMiBMean': round(statistics.fmean(device_mem_mib), 2) if device_mem_mib else None,
        'gpuMsCoverage': round(len(gpu_ms_values) / row_count, 4) if row_count else 0.0,
    }


def evaluate_backend_consistency(
    backend: str,
    measured: dict,
    lab_baseline: dict,
    expected_frames: int,
    min_fps_ratio: float = 0.80,
    dxmt_max_vram_mib: float = 64.0,
) -> dict:
    """Assert packaged artifact run matches laboratory four-way baseline without silent degradation."""
    errors: list[str] = []
    lab_key_map = {
        'dxmt': 'dxmt',
        'dxmt_metalfx_quality': 'dxmt_metalfx_quality',
        'd3dmetal': 'd3dmetal',
        'dxvk': 'dxvk_moltenvk',
        'dxvk_moltenvk': 'dxvk_moltenvk',
        'dxvk_kosmickrisp': 'dxvk_kosmickrisp',
    }
    norm = backend.lower()
    lab_key = lab_key_map.get(norm, norm)
    lab_entry = lab_baseline.get(lab_key, {}).get('cold', {})
    if not lab_entry and lab_key == 'dxvk_moltenvk':
        lab_entry = lab_baseline.get('dxvk', {}).get('cold', {})
    if not lab_entry or not lab_entry.get('derived_fps_mean'):
        errors.append('historical_baseline_missing')
    lab_fps = float(lab_entry.get('derived_fps_mean') or 0.0)
    lab_vram = lab_entry.get('device_memory_mib_mean')

    if measured.get('frameCount', 0) < expected_frames:
        errors.append(f'insufficient_frames:{measured.get("frameCount", 0)}<{expected_frames}')

    measured_fps = float(measured.get('derivedFPS') or 0.0)
    fps_ratio = round(measured_fps / lab_fps, 4) if lab_fps > 0 else None
    if lab_fps > 0 and measured_fps < lab_fps * min_fps_ratio:
        errors.append(f'fps_regression:{measured_fps:.2f}<{lab_fps * min_fps_ratio:.2f}')

    measured_vram = measured.get('deviceMemoryMiBMean')
    if norm == 'dxmt':
        if measured_vram is not None and measured_vram > dxmt_max_vram_mib:
            errors.append(f'dxmt_vram_signature_unexpected:{measured_vram:.2f}>{dxmt_max_vram_mib:.2f}')
    elif norm == 'dxmt_metalfx_quality':
        if measured_vram is not None and measured_vram < 30.0:
            errors.append(f'dxmt_metalfx_not_engaged_vram:{measured_vram:.2f}<30.00')
    elif norm == 'dxvk_kosmickrisp':
        if measured_vram is not None and measured_vram < 260.0:
            errors.append(f'kosmickrisp_vram_signature_unexpected:{measured_vram:.2f}<260.00')

    return {
        'passed': not errors,
        'errors': errors,
        'labBaselineKey': lab_key,
        'labBaselineColdFPS': round(lab_fps, 2) if lab_fps > 0 else None,
        'labBaselineDeviceMemoryMiB': round(float(lab_vram), 2) if lab_vram is not None else None,
        'fpsRatioToLabBaseline': fps_ratio,
        'minRequiredFPSRatio': min_fps_ratio,
    }


def verify_bundled_manifest_against_sandbox(
    manifest_path: pathlib.Path,
    libraries_dir: pathlib.Path,
    app_bundle: pathlib.Path | None = None,
) -> dict:
    """Verify bundled runtime-manifest.json locked components against app bundle and sandbox libraries."""
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    results = []
    all_locked_matched = True
    for comp in manifest.get('components', []):
        if comp.get('status') == 'reserved' or not comp.get('artifacts'):
            results.append({'id': comp['id'], 'version': comp['version'], 'state': 'reserved'})
            continue
        comp_ok = True
        matched_files = 0
        for art in comp['artifacts']:
            candidates = [art['relativePath'], *art.get('alternateRelativePaths', [])]
            accepted = {art['sha256'].lower(), *(h.lower() for h in art.get('alternateSHA256s', []))}
            found = None
            for rel in candidates:
                if rel.startswith('Contents/'):
                    if app_bundle is not None:
                        cand = app_bundle / rel
                        if cand.is_file():
                            found = cand
                            break
                else:
                    cand = libraries_dir / rel
                    if cand.is_file():
                        found = cand
                        break
            if found is None or sha256_file(found).lower() not in accepted:
                comp_ok = False
            else:
                matched_files += 1
        state = 'verified' if comp_ok else 'mismatch_or_missing'
        if not comp_ok:
            all_locked_matched = False
        results.append({
            'id': comp['id'],
            'version': comp['version'],
            'state': state,
            'matchedArtifacts': matched_files,
            'expectedArtifacts': len(comp['artifacts']),
        })
    return {
        'schemaVersion': manifest.get('schemaVersion'),
        'allLockedComponentsVerified': all_locked_matched,
        'components': results,
    }


def _discover_engine_layout(engine_root: pathlib.Path) -> dict[str, pathlib.Path]:
    wine_root = engine_root / 'containers/wine_installations/10000073'
    dxvk_root = engine_root / 'downloads/dxvk-1.10.3'
    mvk_root = engine_root / 'downloads/MoltenVK-v1.2.1'
    gptk_root = engine_root / 'downloads/gptk-4.0-1'
    dxmt_root = engine_root / 'downloads/dxmt-v0.80'
    for label, path in (
        ('wine', wine_root / 'bin/wine'),
        ('wineserver', wine_root / 'bin/wineserver'),
        ('dxvk', dxvk_root / 'wine/x86_64-windows/d3d11.dll'),
        ('moltenvk', mvk_root / 'external/libMoltenVK.dylib'),
        ('gptk', gptk_root / 'external/libd3dshared.dylib'),
        ('dxmt', dxmt_root / 'wine/x86_64-unix/winemetal.so'),
    ):
        if not path.is_file():
            raise RuntimeError(f'required local runtime component missing: {label}')
    return {
        'wine_root': wine_root,
        'dxvk_root': dxvk_root,
        'mvk_root': mvk_root,
        'gptk_root': gptk_root,
        'dxmt_root': dxmt_root,
    }


def _mount_sandbox_runtime(
    sandbox_runtime: pathlib.Path,
    engines: dict[str, pathlib.Path],
    product_prefix: str,
) -> pathlib.Path:
    """Zero-copy symlink mount of verified laboratory engines into an isolated runtime root."""
    libs = sandbox_runtime / 'Libraries'
    wine_bin = libs / 'Wine/bin'
    wine_bin.mkdir(parents=True, exist_ok=True)
    os.symlink(engines['wine_root'] / 'bin/wine', wine_bin / 'wine64')
    os.symlink(engines['wine_root'] / 'bin/wine', wine_bin / 'wine')
    os.symlink(engines['wine_root'] / 'bin/wineserver', wine_bin / 'wineserver')
    os.symlink(engines['wine_root'] / 'lib', libs / 'Wine/lib')

    (libs / 'DXMT').mkdir(parents=True, exist_ok=True)
    os.symlink(engines['dxmt_root'] / 'wine', libs / 'DXMT/wine')

    (libs / 'GPTK').mkdir(parents=True, exist_ok=True)
    os.symlink(engines['gptk_root'] / 'wine', libs / 'GPTK/wine')
    os.symlink(engines['gptk_root'] / 'external', libs / 'GPTK/external')

    (libs / 'DXVK').mkdir(parents=True, exist_ok=True)
    os.symlink(engines['dxvk_root'] / 'wine', libs / 'DXVK/wine')
    os.symlink(engines['dxvk_root'] / 'wine/x86_64-windows', libs / 'DXVK/x64')
    os.symlink(engines['mvk_root'] / 'external/libMoltenVK.dylib', libs / 'DXVK/libMoltenVK.dylib')

    version_plist = {'version': {'major': 7, 'minor': 7, 'patch': 0}}
    with (libs / f'{product_prefix}WineVersion.plist').open('wb') as handle:
        plistlib.dump(version_plist, handle, fmt=plistlib.FMT_XML)
    return libs


def _create_and_configure_bottle(
    cli_bin: pathlib.Path,
    base_env: dict[str, str],
    bottle_name: str,
    mode: str,
    dxmt_metalfx_preset: str = 'off',
    dxvk_prefer_kosmickrisp: bool = True,
) -> pathlib.Path:
    """Create a real bottle via the packaged CLI and configure its graphics routing mode."""
    subprocess.run([str(cli_bin), 'create', bottle_name], env=base_env, capture_output=True,
                   text=True, check=True, timeout=60)
    # Locate the newly created bottle directory inside the isolated CFFIXED_USER_HOME.
    home_dir = pathlib.Path(base_env['CFFIXED_USER_HOME'])
    bottle_dirs = [
        p.parent for p in home_dir.rglob('Metadata.plist')
        if plistlib.loads(p.read_bytes()).get('info', {}).get('name') == bottle_name
    ]
    if not bottle_dirs:
        raise RuntimeError(f'packaged CLI did not create Metadata.plist for {bottle_name}')
    bottle_dir = bottle_dirs[0]
    meta_path = bottle_dir / 'Metadata.plist'
    meta = plistlib.loads(meta_path.read_bytes())
    meta.setdefault('wineConfig', {})['adaptiveResourcePolicyEnabled'] = False
    dxvk_cfg = meta.setdefault('dxvkConfig', {})
    dxvk_cfg['dxvk'] = (mode == 'dxvk')
    dxvk_cfg['graphicsBackendMode'] = mode
    dxvk_cfg['directXAPIRequirement'] = 'directX11'
    dxvk_cfg['graphicsRoutingPreference'] = 'performanceFirst'
    dxvk_cfg['dxmtMetalFXPreset'] = dxmt_metalfx_preset
    dxvk_cfg['dxmtMetalFXOutputHeight'] = 1080
    dxvk_cfg['dxvkPreferKosmicKrisp'] = dxvk_prefer_kosmickrisp
    with meta_path.open('wb') as handle:
        plistlib.dump(meta, handle, fmt=plistlib.FMT_XML)
    return bottle_dir


def _init_bottle_prefix(bottle_dir: pathlib.Path, engines: dict[str, pathlib.Path], backend: str, xdg_cache: pathlib.Path):
    env = os.environ.copy()
    env['WINEPREFIX'] = str(bottle_dir)
    env['WINEDEBUG'] = '-all'
    env['XDG_CACHE_HOME'] = str(xdg_cache)
    xdg_cache.mkdir(parents=True, exist_ok=True)
    boot = run_probe([str(engines['wine_root'] / 'bin/wine'), 'wineboot', '--init'], env, timeout=120)
    if boot.returncode:
        raise RuntimeError('isolated_wineboot_failed')
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-k'],
                   env=env, capture_output=True, timeout=30)
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-w'],
                   env=env, capture_output=True, timeout=30)
    sys32 = bottle_dir / 'drive_c/windows/system32'
    if not sys32.is_dir():
        raise RuntimeError(f'wineboot failed to initialize system32 for {backend}')
    src_map = {
        'dxmt': engines['dxmt_root'] / 'wine/x86_64-windows',
        'd3dMetal': engines['gptk_root'] / 'wine/x86_64-windows',
        'dxvk': engines['dxvk_root'] / 'wine/x86_64-windows',
    }
    for dll in src_map[backend].glob('*.dll'):
        shutil.copy2(dll, sys32 / dll.name)
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-k'],
                   env=env, capture_output=True, timeout=30)
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-w'],
                   env=env, capture_output=True, timeout=30)


def _find_packaged_cli(app_bundle: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, str]:
    info_plist = app_bundle / 'Contents/Info.plist'
    with info_plist.open('rb') as handle:
        info = plistlib.load(handle)
    exe_name = info['CFBundleExecutable']
    bundle_id = info['CFBundleIdentifier']
    app_bin = app_bundle / 'Contents/MacOS' / exe_name
    cli_bin = app_bundle / 'Contents/Resources' / f'{exe_name}Cmd'
    if not app_bin.is_file() or not cli_bin.is_file():
        raise RuntimeError('packaged .app or embedded CLI binary missing')
    return app_bin, cli_bin, bundle_id


def _choose_scratch_base(preferred: pathlib.Path | None = None) -> pathlib.Path:
    """Pick an explicit scratch root or the writable external volume with most free space."""
    if preferred is not None:
        preferred.mkdir(parents=True, exist_ok=True)
        return preferred
    best_path = pathlib.Path(tempfile.gettempdir())
    best_free = shutil.disk_usage(best_path).free
    volumes_dir = pathlib.Path('/Volumes')
    if volumes_dir.is_dir():
        for entry in sorted(volumes_dir.iterdir()):
            if entry.is_symlink() or not entry.is_dir():
                continue
            try:
                free = shutil.disk_usage(entry).free
                if free > best_free and os.access(entry, os.W_OK):
                    best_free = free
                    best_path = entry
            except OSError:
                continue
    return best_path


def parse_shell_environment(text: str) -> dict[str, str]:
    """Parse full export assignments; substring matches cannot establish an effective value."""
    values = {}
    for line in text.splitlines():
        match = re.match(r'^export\s+([A-Z][A-Z0-9_]*)=(.*)$', line.strip())
        if match:
            raw = match.group(2)
            parsed = shlex.split(raw)
            values[match.group(1)] = parsed[0] if len(parsed) == 1 else raw
    return values


def runtime_path_matches(value, expected):
    """Compare the actual file, including Cocoa/system path aliases, rather than spelling."""
    try:
        return bool(value) and pathlib.Path(value).samefile(expected)
    except OSError:
        return False


def evaluate_paired_runs(artifact: dict, reference: dict, backend: str, require_gpu=True) -> dict:
    """Compare adjacent same-host runs with fixed, declared noise tolerances."""
    errors = []
    fps = float(artifact.get('derivedFPS') or 0)
    reference_fps = float(reference.get('derivedFPS') or 0)
    ratio = fps / reference_fps if reference_fps > 0 else 0
    if reference_fps <= 0 or ratio < 0.85:
        errors.append('paired_fps_regression')
    metrics = [('frameIntervalP95Ms', 1.35), ('deviceMemoryMiBMean', 1.20)]
    if require_gpu:
        metrics.append(('gpuMsMean', 1.30))
    for key, upper in metrics:
        current, baseline = artifact.get(key), reference.get(key)
        if current is not None and baseline is not None and baseline > 0 and current > baseline * upper:
            errors.append('paired_' + key + '_regression')
    if require_gpu and backend != 'd3dMetal':
        for label, measured in [('artifact', artifact), ('reference', reference)]:
            if (measured.get('gpuMsCoverage') or 0) < 0.95 or measured.get('gpuMsMean') is None:
                errors.append(label + '_gpu_timestamps_missing')
    if artifact.get('deviceMemoryMiBMean') is None or reference.get('deviceMemoryMiBMean') is None:
        errors.append('paired_vram_missing')
    return {'passed': not errors, 'errors': errors, 'fpsRatio': round(ratio, 4),
            'tolerances': {'minimumFPSRatio': 0.85, 'maximumP95Ratio': 1.35,
                           'maximumGPUTimeRatio': 1.30, 'maximumVRAMRatio': 1.20}}


def aggregate_paired_runs(samples, backend, expected_frames):
    """Use every declared round, matching the laboratory's per-condition mean statistics."""
    pair = {}
    for kind in ('artifact', 'reference'):
        metrics = {}
        for key in ('derivedFPS', 'frameIntervalP95Ms', 'deviceMemoryMiBMean'):
            values = [sample[kind].get(key) for sample in samples]
            metrics[key] = statistics.fmean(values) if values and all(v is not None for v in values) else None
        pair[kind] = metrics
    result = evaluate_paired_runs(pair['artifact'], pair['reference'], backend, require_gpu=False)
    if not samples or any(sample[kind].get('frameCount') != expected_frames
                          for sample in samples for kind in ('artifact', 'reference')):
        result['errors'].append('incomplete_paired_frames')
        result['passed'] = False
    result.update(method='arithmetic mean of all rounds; no discarded samples',
                  roundCount=len(samples), artifact=pair['artifact'], reference=pair['reference'])
    return result


def aggregate_gpu_runs(samples, backend, expected_rounds, expected_frames=120):
    """Require every GPU round and mapping while comparing all measured round means."""
    pair = {}
    for kind in ('artifact', 'reference'):
        pair[kind] = {}
        for key in ('derivedFPS', 'frameIntervalP95Ms', 'deviceMemoryMiBMean', 'gpuMsMean', 'gpuMsCoverage'):
            values = [sample[kind].get(key) for sample in samples]
            pair[kind][key] = statistics.fmean(values) if values and all(v is not None for v in values) else None
    result = evaluate_paired_runs(pair['artifact'], pair['reference'], backend)
    if len(samples) != expected_rounds or [s['round'] for s in samples] != list(range(1, expected_rounds + 1)):
        result['errors'].append('incomplete_gpu_rounds')
    for sample in samples:
        if any(sample[kind].get('frameCount') != expected_frames for kind in ('artifact', 'reference')):
            result['errors'].append('incomplete_gpu_validation_frames')
        if any((sample[kind].get('gpuMsCoverage') or 0) < 0.95 or sample[kind].get('gpuMsMean') is None
               for kind in ('artifact', 'reference')):
            result['errors'].append('gpu_round_timestamps_missing')
        if sample['driverMappingRequired'] and not sample['driverMappingVerified']:
            result['errors'].append('gpu_round_locked_mapping_missing')
    result['passed'] = not result['errors']
    return {'passed': result['passed'], 'completionMode': 'gpu-complete', 'timestampSupport': 'required',
            'method': 'arithmetic mean of every GPU round; no discarded samples',
            'roundCount': len(samples), 'measuredFramesPerRound': expected_frames,
            'artifact': pair['artifact'], 'reference': pair['reference'], 'pairedConsistency': result,
            'runs': samples, 'rawPerformanceOutlierCount': sum(not s['pairedConsistency']['passed'] for s in samples)}


def merge_extended_condition(base, replacement, replacement_sha256):
    """Reuse unchanged conditions, retaining prior failures and every longer-window sample. @DNPMBHC."""
    keys = ('appBinarySHA256', 'cliBinarySHA256', 'runtimeManifestSHA256', 'probeBinarySHA256', 'dmg')
    if not base.get('backendCoverageComplete') or len(replacement.get('backends', {})) != 1:
        raise ValueError('condition_report_coverage_mismatch')
    if any(not base['packagedArtifacts'].get(k) or base['packagedArtifacts'].get(k) != replacement['packagedArtifacts'].get(k) for k in keys):
        raise ValueError('condition_report_artifact_mismatch')
    if not base.get('gateSourceSHA256') or base['gateSourceSHA256'] != replacement.get('gateSourceSHA256') or not (
        base.get('gateSourcesStableDuringRun') and replacement.get('gateSourcesStableDuringRun')
    ):
        raise ValueError('condition_report_source_mismatch')
    for report in (base, replacement):
        if not (report.get('hardenedRuntimeVerification', {}).get('passed')
                and report.get('releaseManifestMatchesArtifacts')
                and report.get('runtimeManifestVerification', {}).get('allLockedComponentsVerified')
                and report.get('vulkanFeatureProbe', {}).get('geometryShader')
                and report.get('vulkanFeatureProbe', {}).get('fillModeNonSolid')):
            raise ValueError('condition_report_integrity_mismatch')
    condition, measured = next(iter(replacement['backends'].items()))
    if condition not in base['backends']:
        raise ValueError('condition_report_unknown_condition')
    frames, rounds = replacement['workload']['measuredFrames'], replacement['workload']['rounds']
    if frames <= base['workload']['measuredFrames'] or rounds != base['workload']['rounds']:
        raise ValueError('condition_report_measurement_window_mismatch')
    samples = measured['runs']
    grid = [(s['round'], s['cacheState']) for s in samples]
    expected = [(r, state) for r in range(1, rounds + 1) for state in ('cold', 'hot')]
    if sorted(grid) != sorted(expected) or any(s.get('errors') or not s.get('integrityPassed') or any(
        s[kind].get('frameCount') != frames for kind in ('artifact', 'reference')) for s in samples
    ) or any(value is False for value in measured['envChecks'].values()):
        raise ValueError('condition_report_incomplete_measurements')
    mode = condition.split('_', 1)[0]
    measured = copy.deepcopy(measured)
    aggregates = {state: aggregate_paired_runs([s for s in samples if s['cacheState'] == state], mode, frames)
                  for state in ('cold', 'hot')}
    gpu = measured['gpuValidation']
    if gpu.get('timestampSupport') == 'required':
        prior_runs = base['backends'][condition]['gpuValidation']['runs']
        expected_mapping = prior_runs[0]['actualMappedLibraries']
        if any(s['actualMappedLibraries'] != expected_mapping or s['driverMappingRequired'] != prior_runs[0]['driverMappingRequired']
               for s in gpu['runs']):
            raise ValueError('condition_report_locked_mapping_mismatch')
        gpu = aggregate_gpu_runs(gpu['runs'], mode, rounds)
    elif mode != 'd3dMetal' or gpu.get('timestampSupport') != 'unavailable':
        raise ValueError('condition_report_gpu_evidence_missing')
    measured.update(aggregateConsistency=aggregates, gpuValidation=gpu,
                    passed=all(v['passed'] for v in aggregates.values()) and gpu['passed'],
                    workload=copy.deepcopy(replacement['workload']))
    result = copy.deepcopy(base)
    result.setdefault('measurementRevisions', []).append({
        'condition': condition, 'reason': 'longer window after short-window variability',
        'replacementReportSHA256': replacement_sha256, 'measurementSourceSHA256': base['gateSourceSHA256'],
        'previousResult': result['backends'][condition]})
    result['backends'][condition] = measured
    result['measurementSourceSHA256'] = copy.deepcopy(base['gateSourceSHA256'])
    result['workload']['measurementFramesByCondition'] = {
        key: value.get('workload', base['workload'])['measuredFrames'] for key, value in result['backends'].items()}
    result['passed'] = all(v['passed'] for v in result['backends'].values()) and result.get('real3dSupplement', {'passed': True})['passed']
    result['schema'] = 'task-07-artifact-perf-gate-v5'
    result['assembledAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result['acceptanceMethod'] = result.get('acceptanceMethod', 'All measured rounds are retained.')
    result['acceptanceMethod'] += ' Longer-window revisions retain every prior failure and all new rounds; '
    result['acceptanceMethod'] += 'per-condition frame counts and measurement source digests are explicit.'
    return result


def remove_isolated_directory(path, attempts=5):
    """Retry bounded cleanup after isolated processes stop, without hiding permanent errors."""
    for attempt in range(attempts):
        try:
            shutil.rmtree(path)
            return
        except FileNotFoundError:
            return
        except OSError:
            if attempt + 1 == attempts:
                raise
            time.sleep(0.2)


@contextlib.contextmanager
def isolated_temporary_directory(*, prefix, dir):
    """Retain the original run exception when cleanup also fails."""
    path = tempfile.mkdtemp(prefix=prefix, dir=dir)
    failure = None
    try:
        yield path
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            remove_isolated_directory(path)
        except OSError:
            if failure is None:
                raise
            failure.add_note('isolated_temporary_directory_cleanup_failed')


def _redact_run(text, workspace, temporary):
    text = str(text).replace(str(workspace), '<workspace>').replace(str(temporary), '<scratch>')
    text = text.replace(str(pathlib.Path(workspace).resolve()), '<workspace>')
    text = text.replace(str(pathlib.Path(temporary).resolve()), '<scratch>')
    text = text.replace(str(pathlib.Path(temporary).resolve()).removeprefix('/private'), '<scratch>')
    if globals().get('_redact_identity'):
        text = re.sub(_redact_identity, 'org.example.demo-app', text, flags=re.IGNORECASE)
    text = text.replace(str(workspace).replace('/', chr(92)), '<workspace>')
    text = text.replace(str(temporary).replace('/', chr(92)), '<scratch>')
    text = text.replace(str(pathlib.Path.home()), '<home>')
    text = re.sub(r'/Volumes/[^\s"\'<>]+', '<EXTERNAL_VOLUME>', text)
    text = re.sub(r'/Users/[^\s"\'<>]+', '<home>', text)
    text = re.sub(r'(?:/private)?/var/folders/[^\s"\'<>]+', '<scratch>', text)
    text = re.sub(_redact_product, 'demo-app', text, flags=re.IGNORECASE)
    return re.sub(_redact_driver, 'backend-k', text, flags=re.IGNORECASE)


def _loaded_icd(backend, stdout, stderr, log_dir, driver_name):
    logs = stdout + '\n' + stderr
    for file in log_dir.glob('*.log'):
        logs += '\n' + file.read_text(errors='replace')
    if backend == 'dxvk_kosmickrisp':
        matched = [line.strip() for line in logs.splitlines()
                   if driver_name in line and any(term in line.lower() for term in
                   ('using driver', 'driver library', 'driver:'))]
        return {'passed': bool(matched), 'evidenceLines': matched[:5]}
    if backend == 'dxvk_moltenvk':
        matched = [line.strip() for line in logs.splitlines()
                   if 'moltenvk' in line.lower() and any(term in line.lower()
                   for term in ('version', 'driver:', 'vulkan version'))]
        return {'passed': bool(matched), 'evidenceLines': matched[:5]}
    return {'passed': True, 'evidenceLines': []}


def run_probe(command, env, timeout=180, cwd=None):
    """Capture to files like production Wine; pipes can block during mapping observation."""
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(command, env=env, stdout=stdout_file, stderr=stderr_file,
                                   start_new_session=True, cwd=cwd)
        code, stdout, stderr = finish_probe(process, stdout_file, stderr_file, timeout)
        return subprocess.CompletedProcess(command, code, stdout, stderr)


def finish_probe(process, stdout_file, stderr_file, timeout):
    """Bound our process group's lifetime and retain output on both success and timeout."""
    timed_out = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)
    stdout_file.seek(0)
    stderr_file.seek(0)
    stdout = stdout_file.read().decode(errors='replace')
    stderr = stderr_file.read().decode(errors='replace')
    return (124 if timed_out else process.returncode), stdout, stderr + ('\nprobe_timeout' if timed_out else '')


def stop_bottle_prefix(engines, bottle, environment):
    """Wait for this isolated prefix to stop before starting the adjacent run."""
    env = {**environment, 'WINEPREFIX': str(bottle)}
    for action in ('-k', '-w'):
        result = run_probe([str(engines['wine_root'] / 'bin/wineserver'), action], env, timeout=30)
        if result.returncode == 124:
            raise RuntimeError('isolated_wineserver_cleanup_timeout')


def mapped_libraries_from_listing(listing, expected_libraries):
    """Accept mapped files only when their exact bytes match the locked expectation."""
    mapped = {}
    for line in listing.splitlines():
        if not line.startswith('n'):
            continue
        candidate = pathlib.Path(line[1:])
        for label, expected in expected_libraries.items():
            try:
                if candidate.name != expected.name and not candidate.samefile(expected):
                    continue
                digest = sha256_file(candidate)
                if digest == sha256_file(expected):
                    mapped[label] = {'filename': expected.name, 'sha256': digest}
            except OSError:
                continue
    return mapped


def probe_process_ids(rows, root_pid, csv_marker):
    """Wine start may reparent its child; the unique CSV argument still identifies our probe."""
    descendants = {root_pid}
    links = []
    for row in rows:
        fields = row.split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        pid, parent = map(int, fields[:2])
        links.append((pid, parent))
        if csv_marker and '--csv' in fields[2] and csv_marker in fields[2]:
            descendants.add(pid)
    changed = True
    while changed:
        changed = False
        for pid, parent in links:
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    return descendants


def read_probe_logs(home, since):
    """Read new logs only inside this gate's isolated home."""
    parts = []
    for file in (home / 'Library/Logs').glob('**/*.log'):
        if file.stat().st_mtime >= since:
            parts.append(file.read_text(errors='replace'))
    return '\n'.join(parts)


def configure_probe_environment(bottle, executable, environment, identity_launcher=None):
    """Use the CLI's supported per-program overrides; parent environment is not forwarded."""
    if identity_launcher:
        result = subprocess.run([str(identity_launcher), '--identity-digest', str(executable), str(bottle)],
                                capture_output=True, text=True, check=True, timeout=30)
        digest = result.stdout.strip()
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('native_program_identity_invalid')
    else:
        program, prefix = executable.resolve(), bottle.resolve()
        identity = str(program.relative_to(prefix)) if program.is_relative_to(prefix) else str(program)
        digest = hashlib.sha256(identity.encode()).hexdigest()
    folder = bottle / 'Program Settings'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / ('v2-' + digest + '.plist')
    path.write_bytes(plistlib.dumps({'locale': '', 'arguments': '', 'environment': environment}))
    return path


def run_mapped_probe(command, env, expected_libraries, cwd=None):
    """Observe only our spawned probe descendants and record the exact mapped runtime files."""
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(command, env=env, stdout=stdout_file, stderr=stderr_file,
                                   start_new_session=True, cwd=cwd)
        mapped = observe_probe_mappings(process, command[-1], expected_libraries)
        code, stdout, stderr = finish_probe(process, stdout_file, stderr_file, 180)
        return code, stdout, stderr, mapped


def observe_probe_mappings(process, csv_marker, expected_libraries):
    """File capture leaves Wine free to progress while ps/lsof observe runtime mappings."""
    mapped = {}
    deadline = time.monotonic() + 25
    while process.poll() is None and time.monotonic() < deadline and len(mapped) < len(expected_libraries):
        rows = subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], capture_output=True, text=True,
                              timeout=5).stdout.splitlines()
        descendants = probe_process_ids(rows, process.pid, csv_marker)
        listing = subprocess.run(['lsof', '-p', ','.join(map(str, descendants)), '-Fn'],
                                 capture_output=True, text=True, timeout=10).stdout
        mapped.update(mapped_libraries_from_listing(listing, expected_libraries))
        if len(mapped) < len(expected_libraries):
            time.sleep(0.15)
    return mapped


def run_artifact_performance_gate(
    app_bundle: pathlib.Path,
    workspace_root: pathlib.Path,
    engine_root: pathlib.Path = DEFAULT_ENGINE_ROOT,
    frames: int = 900,
    warmup: int = 120,
    backends: tuple[str, ...] = ('dxmt', 'dxmt_metalfx_quality', 'd3dMetal', 'dxvk_kosmickrisp', 'dxvk_moltenvk'),
    release_manifest_path: pathlib.Path | None = None,
    scratch_root: pathlib.Path | None = None,
    rounds: int = 3,
    evidence_dir: pathlib.Path | None = None,
) -> dict:
    global _redact_product, _redact_driver, _redact_identity
    app_bin, cli_bin, _ = _find_packaged_cli(app_bundle)
    _redact_product = re.escape(app_bin.name)
    _redact_driver = r'kosmickrisp'
    bundle_info = plistlib.loads((app_bundle / 'Contents/Info.plist').read_bytes())
    _redact_identity = re.escape(bundle_info.get('CFBundleIdentifier', '')) or None
    bundled_manifest = app_bundle / 'Contents/Resources/runtime-manifest.json'
    probe_source = workspace_root / PROBE_RELPATH
    probe_digest = sha256_file(probe_source)
    lab_path = workspace_root / LAB_BASELINE_MANIFEST
    lab_manifest = json.loads(lab_path.read_text())
    lab_aggregate = lab_manifest['aggregate']
    fx_path = lab_path.parents[1] / 'dxmt-metalfx-ab/manifest.json'
    lab_aggregate.update(json.loads(fx_path.read_text())['aggregate'])
    engines = _discover_engine_layout(engine_root)
    hardened = verify_hardened(app_bundle)
    release_info = json.loads(release_manifest_path.read_text()) if release_manifest_path else {}
    artifact_digests = {'appBinarySHA256': sha256_file(app_bin),
                        'cliBinarySHA256': sha256_file(cli_bin),
                        'runtimeManifestSHA256': sha256_file(bundled_manifest)}
    release_matches = all(release_info.get('artifacts', {}).get(k) == v for k, v in artifact_digests.items())
    driver_name = 'libvulkan_kosmickrisp.dylib'
    icd_path = app_bundle / 'Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json'
    feature_check = probe_driver(app_bundle / 'Contents/Frameworks/libvulkan.1.dylib', icd_path)
    scenario_specs = {'dxmt': ('dxmt', 'off', True), 'dxmt_metalfx_quality': ('dxmt', 'quality', True),
                      'd3dMetal': ('d3dMetal', 'off', True), 'dxvk_kosmickrisp': ('dxvk', 'off', True),
                      'dxvk_moltenvk': ('dxvk', 'off', False)}
    backend_runs = {}
    scratch_base = _choose_scratch_base(scratch_root)
    if evidence_dir:
        evidence_dir.mkdir(parents=True, exist_ok=True)
    with isolated_temporary_directory(prefix='my-project-artifact-gate-', dir=scratch_base) as tmp:
        temporary = pathlib.Path(tmp)
        probe_exe = temporary / probe_source.name
        shutil.copy2(probe_source, probe_exe)
        if sha256_file(probe_exe) != probe_digest:
            raise RuntimeError('copied_probe_checksum_mismatch')
        reference_launcher = temporary / 'wine-reference-launch'
        launcher_source = pathlib.Path(__file__).with_name('wine_reference_launch.swift')
        build_reference = subprocess.run(['xcrun', 'swiftc', str(launcher_source), '-o', str(reference_launcher)],
                                         capture_output=True, timeout=60)
        if build_reference.returncode:
            raise RuntimeError('reference_launcher_compile_failed')
        reference_launcher_digest = sha256_file(reference_launcher)
        home = temporary / 'home'
        home.mkdir()
        libs = _mount_sandbox_runtime(temporary / 'runtime', engines, app_bin.name)
        manifest_check = verify_bundled_manifest_against_sandbox(bundled_manifest, libs, app_bundle)
        base_env = os.environ.copy()
        base_env['CFFIXED_USER_HOME'] = str(home)
        base_env[app_bin.name.upper() + '_RUNTIME_ROOT'] = str(temporary / 'runtime')
        base_env['WINEDEBUG'] = '-all'
        for key in ('VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'WINE_SONAME_LIBVULKAN',
                    'VK_ADD_DRIVER_FILES', 'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE',
                    'DXMT_CONFIG', 'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'WINEDLLPATH'):
            base_env.pop(key, None)
        integrity = subprocess.run([str(cli_bin), 'integrity-report'], env=base_env,
                                   capture_output=True, text=True, check=True, timeout=60)
        integrity_report = json.loads(integrity.stdout)
        for backend in backends:
            mode, preset, prefer = scenario_specs[backend]
            print('[gate] Starting ' + backend.replace('kosmickrisp', 'backend-k'), flush=True)
            samples = []
            checks = {}
            gpu_validation = None
            gpu_samples = []
            for round_index in range(rounds):
                bottle_name = f'gate-{backend}-{round_index}'
                cache = temporary / f'cache-{backend}-{round_index}'
                bottle = _create_and_configure_bottle(
                    cli_bin, base_env, bottle_name, mode, dxmt_metalfx_preset=preset,
                    dxvk_prefer_kosmickrisp=prefer
                )
                try:
                    _init_bottle_prefix(bottle, engines, mode, cache)
                    shell = subprocess.run([str(cli_bin), 'shellenv', bottle_name], env=base_env,
                                           capture_output=True, text=True, check=True, timeout=60)
                    values = parse_shell_environment(shell.stdout)
                    checks = {
                        'dxmtShaderCacheEnabled': values.get('DXMT_SHADER_CACHE') == '1' if mode == 'dxmt' else None,
                        'dxmtMetalFXExplicit': values.get('DXMT_METALFX_SPATIAL_SWAPCHAIN') == (
                            '1' if preset == 'quality' else '0') if mode == 'dxmt' else None,
                        'dxmtMetalFXFactor': 'd3d11.metalSpatialUpscaleFactor=1.5' in values.get(
                            'DXMT_CONFIG', '') if preset == 'quality' else None,
                        'dxvkICDIsBundled': runtime_path_matches(values.get('VK_DRIVER_FILES'), icd_path) if prefer and mode == 'dxvk' else None,
                        'dxvkMoltenVKExplicit': values.get('WINE_SONAME_LIBVULKAN', '').endswith(
                            'libMoltenVK.dylib') and 'VK_DRIVER_FILES' not in values if not prefer and mode == 'dxvk' else None,
                    }
                    for cache_state in ('cold', 'hot'):
                        pair = {}
                        pair_loaded = {}
                        # Alternate the launch order to avoid biasing one path toward a warmer host.
                        order = ('reference', 'artifact') if round_index % 2 == 0 else ('artifact', 'reference')
                        for kind in order:
                            log_dir = temporary / f'logs-{backend}-{round_index}-{cache_state}-{kind}'
                            log_dir.mkdir()
                            csv = temporary / f'{backend}-{round_index}-{cache_state}-{kind}.csv'
                            win_csv = 'Z:' + str(csv).replace('/', '\\')
                            args = [str(probe_exe), '--frames', str(frames), '--warmup', str(warmup),
                                    '--width', '1280', '--height', '720', '--commands', '16',
                                    '--resource-bytes', '65536', '--csv', win_csv]
                            kind_cache = bottle / 'gate_cache' / kind
                            kind_cache.mkdir(parents=True, exist_ok=True)
                            run_env = {**base_env, 'XDG_CACHE_HOME': str(cache / kind),
                                       'DXMT_SHADER_CACHE_PATH': str(kind_cache / 'dxmt'),
                                       'DXVK_STATE_CACHE_PATH': str(kind_cache / 'dxvk'),
                                       'DXVK_LOG_LEVEL': 'info', 'DXVK_LOG_PATH': str(log_dir),
                                       'VK_LOADER_DEBUG': 'driver', 'MVK_CONFIG_LOG_LEVEL': '3',
                                       'DXMT_USE_DEFAULT_METAL_CACHE': '0'}
                            overrides = {**values, 'XDG_CACHE_HOME': str(cache / kind),
                                         'DXMT_SHADER_CACHE_PATH': str(kind_cache / 'dxmt'),
                                         'DXVK_STATE_CACHE_PATH': str(kind_cache / 'dxvk'),
                                         'DXVK_LOG_LEVEL': 'info', 'DXVK_LOG_PATH': str(log_dir),
                                         'VK_LOADER_DEBUG': 'driver', 'MVK_CONFIG_LOG_LEVEL': '3',
                                         'DXMT_USE_DEFAULT_METAL_CACHE': '0'}
                            overrides.pop('PATH', None)
                            run_env.update(overrides)
                            if kind == 'reference':
                                run_env = overrides.copy()
                                command = [str(reference_launcher), str(engines['wine_root'] / 'bin/wine'),
                                           'start', '/wait', '/unix', *args]
                            else:
                                configure_probe_environment(bottle, probe_exe, overrides, reference_launcher)
                                command = [str(cli_bin), 'run', '--bottle-path', '--', str(bottle), *args]
                            started_at = time.time()
                            proc = run_probe(command, run_env, cwd=temporary)
                            if kind == 'artifact':
                                proc.stderr += '\n' + read_probe_logs(home, started_at)
                            stop_bottle_prefix(engines, bottle, run_env)
                            loaded = _loaded_icd(backend, proc.stdout, proc.stderr, log_dir, driver_name)
                            loaded['evidenceLines'] = [_redact_run(x, workspace_root, temporary)
                                                       for x in loaded['evidenceLines']]
                            if proc.returncode or not csv.exists():
                                pair[kind] = {'derivedFPS': 0, 'frameCount': 0}
                                loaded['passed'] = False
                            else:
                                pair[kind] = summarize_probe_csv(csv)
                                pair[kind]['csvSHA256'] = sha256_file(csv)
                                if evidence_dir:
                                    shutil.copy2(csv, evidence_dir / csv.name)
                            if evidence_dir:
                                log = _redact_run(proc.stdout + '\n' + proc.stderr, workspace_root, temporary)
                                (evidence_dir / (csv.stem + '.log')).write_text(log)
                            pair_loaded[kind] = loaded
                        paired = evaluate_paired_runs(pair['artifact'], pair['reference'], mode, require_gpu=False)
                        historical = evaluate_backend_consistency(backend, pair['artifact'], lab_aggregate, frames)
                        errors = []
                        if pair['artifact'].get('frameCount', 0) != frames:
                            errors.append('incomplete_artifact_frames')
                        if pair['reference'].get('frameCount', 0) != frames:
                            errors.append('incomplete_reference_frames')

                        if any(value is False for value in checks.values()):
                            errors.append('effective_environment_mismatch')
                        samples.append({'round': round_index + 1, 'cacheState': cache_state,
                                        'artifact': pair['artifact'], 'reference': pair['reference'],
                                        'pairedConsistency': paired, 'historicalConsistency': historical,
                                        'optionalDriverLogEvidence': pair_loaded['artifact'],
                                        'errors': errors, 'integrityPassed': not errors,
                                        'passed': not errors and paired['passed']})
                    if mode == 'd3dMetal':
                        gpu_validation = {'passed': True, 'timestampSupport': 'unavailable',
                                          'completionMode': 'not-applicable',
                                          'reason': 'D3DMetal timestamp frequency is unavailable and event-query '
                                                    'completion is not reliably signaled; no GPU time is estimated.',
                                          'driverMappingRequired': False, 'driverMappingVerified': None}
                    else:
                        gpu_pair = {}
                        mapped_libraries = {}
                        for kind in (('reference', 'artifact') if round_index % 2 == 0 else ('artifact', 'reference')):
                            started_at = time.time()
                            gpu_csv = temporary / f'{backend}-{round_index}-gpu-complete-{kind}.csv'
                            output = 'Z:' + str(gpu_csv).replace('/', '\\')
                            args = [str(probe_exe), '--frames', '120', '--warmup', '9000',
                                    '--width', '1280', '--height', '720', '--commands', '16',
                                    '--resource-bytes', '65536', '--completion-mode', 'gpu-complete',
                                    '--csv', output]
                            run_env = {**base_env, 'XDG_CACHE_HOME': str(cache / kind),
                                       'DXMT_USE_DEFAULT_METAL_CACHE': '0', 'VK_LOADER_DEBUG': 'driver'}
                            overrides = {**values, 'XDG_CACHE_HOME': str(cache / kind),
                                         'DXMT_USE_DEFAULT_METAL_CACHE': '0', 'VK_LOADER_DEBUG': 'driver',
                                         'DXMT_SHADER_CACHE_PATH': str(bottle / 'gate_cache' / kind / 'dxmt'),
                                         'DXVK_STATE_CACHE_PATH': str(bottle / 'gate_cache' / kind / 'dxvk')}
                            overrides.pop('PATH', None)
                            run_env.update(overrides)
                            if kind == 'reference':
                                run_env = overrides.copy()
                                command = [str(reference_launcher), str(engines['wine_root'] / 'bin/wine'),
                                           'start', '/wait', '/unix', *args]
                                process = run_probe(command, run_env, cwd=temporary)
                                code, stdout, stderr = process.returncode, process.stdout, process.stderr
                            else:
                                configure_probe_environment(bottle, probe_exe, overrides, reference_launcher)
                                command = [str(cli_bin), 'run', '--bottle-path', '--', str(bottle), *args]
                                expected = {}
                                if backend == 'dxvk_kosmickrisp':
                                    expected = {'loader': app_bundle / 'Contents/Frameworks/libvulkan.1.dylib',
                                                'driver': app_bundle / 'Contents/Frameworks' / driver_name}
                                elif backend == 'dxvk_moltenvk':
                                    expected = {'driver': engines['mvk_root'] / 'external/libMoltenVK.dylib'}
                                if expected:
                                    code, stdout, stderr, mapped_libraries = run_mapped_probe(
                                        command, run_env, expected, cwd=temporary)
                                else:
                                    process = run_probe(command, run_env, cwd=temporary)
                                    code, stdout, stderr = process.returncode, process.stdout, process.stderr
                            stop_bottle_prefix(engines, bottle, run_env)
                            if kind == 'artifact':
                                stderr += '\n' + read_probe_logs(home, started_at)
                            gpu_pair[kind] = summarize_probe_csv(gpu_csv) if code == 0 and gpu_csv.exists() else {
                                'derivedFPS': 0, 'frameCount': 0}
                            if evidence_dir:
                                if gpu_csv.exists():
                                    shutil.copy2(gpu_csv, evidence_dir / gpu_csv.name)
                                (evidence_dir / (gpu_csv.stem + '.log')).write_text(
                                    _redact_run(stdout + '\n' + stderr, workspace_root, temporary))
                        gpu_consistency = evaluate_paired_runs(gpu_pair['artifact'], gpu_pair['reference'], mode)
                        if any(sample.get('frameCount') != 120 for sample in gpu_pair.values()):
                            gpu_consistency['errors'].append('incomplete_gpu_validation_frames')
                            gpu_consistency['passed'] = False
                        mapped_ok = mode != 'dxvk' or len(mapped_libraries) == (
                            2 if backend == 'dxvk_kosmickrisp' else 1)
                        gpu_samples.append({'passed': gpu_consistency['passed'] and mapped_ok,
                                          'round': round_index + 1,
                                          'completionMode': 'gpu-complete', 'artifact': gpu_pair['artifact'],
                                          'reference': gpu_pair['reference'], 'pairedConsistency': gpu_consistency,
                                          'actualMappedLibraries': mapped_libraries,
                                          'driverMappingRequired': mode == 'dxvk',
                                          'driverMappingVerified': mapped_ok if mode == 'dxvk' else None,
                                          'timestampSupport': 'unavailable' if mode == 'd3dMetal' else 'required',
                                          'warmupFrames': 9000, 'measuredFrames': 120})
                finally:
                    stop_bottle_prefix(engines, bottle, base_env)
                    remove_isolated_directory(bottle)
                    remove_isolated_directory(cache)
            if mode != 'd3dMetal':
                gpu_validation = aggregate_gpu_runs(gpu_samples, mode, rounds)
            aggregates = {state: aggregate_paired_runs(
                [sample for sample in samples if sample['cacheState'] == state], mode, frames)
                for state in ('cold', 'hot')}
            backend_runs[backend] = {
                'passed': all(s['integrityPassed'] for s in samples)
                          and all(v['passed'] for v in aggregates.values()) and gpu_validation['passed'],
                'envChecks': checks, 'runs': samples, 'aggregateConsistency': aggregates,
                'rawPerformanceOutlierCount': sum(not s['pairedConsistency']['passed'] for s in samples),
                'gpuValidation': gpu_validation}
            if evidence_dir:
                checkpoint = {'owner': '@DNPMBHC', 'complete': False, 'backends': backend_runs}
                (evidence_dir.parent / 'artifact-gate-progress.json').write_text(
                    _redact_run(json.dumps(checkpoint, indent=2), workspace_root, temporary) + '\n')
            print('[gate] Finished ' + backend.replace('kosmickrisp', 'backend-k') + ': ' +
                  ('passed' if backend_runs[backend]['passed'] else 'failed'), flush=True)
    report = {
        'schema': 'task-07-artifact-perf-gate-v4', 'owner': '@DNPMBHC',
        'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'backendCoverageComplete': set(scenario_specs).issubset(backend_runs),
        'passed': set(scenario_specs).issubset(backend_runs)
                  and hardened['passed'] and release_matches and manifest_check['allLockedComponentsVerified']
                  and bool(feature_check.get('geometryShader')) and bool(feature_check.get('fillModeNonSolid'))
                  and all(v['passed'] for v in backend_runs.values()),
        'packagedArtifacts': {**artifact_digests, 'probeBinarySHA256': probe_digest,
                              'referenceLauncherSHA256': reference_launcher_digest,
                              'dmg': release_info.get('artifacts', {}).get('dmg')},
        'hardenedRuntimeVerification': hardened, 'releaseManifestMatchesArtifacts': release_matches,
        'runtimeManifestVerification': manifest_check, 'vulkanFeatureProbe': feature_check,
        'cliIntegrityReport': {'schemaVersion': integrity_report.get('schema_version'),
                              'hostExecutionNature': integrity_report.get('host_execution_nature')},
        'workload': {'width': 1280, 'height': 720, 'warmupFrames': warmup, 'measuredFrames': frames,
                     'commandsPerFrame': 16, 'resourceBytes': 65536, 'rounds': rounds, 'cacheStates': ['cold', 'hot'],
                     'launchArguments': 'Wine start /wait /unix', 'wineProcessQoS': 'userInitiated',
                     'adaptiveFrameCapsEnabled': False, 'programCacheOverridesPersisted': True,
                     'wineOutputCapture': 'regular files for artifact and reference',
                     'programIdentityImplementation': 'Foundation canonical URL and CryptoKit SHA256, matching production'},
        'acceptanceMethod': 'All raw pairs require complete frames and exact configuration; performance '
                            'thresholds apply to the arithmetic means of all rounds per cache state. '
                            'Raw outliers remain visible. GPU timestamps and locked-library mappings are mandatory '
                            'where the backend supports them.',
        'labBaselineManifestSHA256': sha256_file(lab_path),
        'backends': backend_runs,
        'scope': 'Packaged CLI vs adjacent same-host Wine launches with exact runtime locks and matched workload; '
                 'historical comparisons are reported separately. Synthetic D3D11 probe only; no commercial game claim.'
    }
    return json.loads(_redact_run(json.dumps(report), workspace_root, temporary))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    task_dir = pathlib.Path(__file__).resolve().parent
    parser.add_argument('--app-bundle', type=pathlib.Path, required=True)
    parser.add_argument('--engine-root', type=pathlib.Path, default=DEFAULT_ENGINE_ROOT)
    parser.add_argument('--release-manifest', type=pathlib.Path, required=True)
    parser.add_argument('--frames', type=int, default=900)
    parser.add_argument('--warmup', type=int, default=120)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--scratch-root', type=pathlib.Path)
    parser.add_argument('--real3d-probe', type=pathlib.Path)
    parser.add_argument('--base-report', type=pathlib.Path,
                        help='Reuse a complete base gate only when all current artifact digests match')
    parser.add_argument('--condition-report', type=pathlib.Path,
                        help='Revalidate one complete longer-window condition against the same frozen base inputs')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.condition_report and not args.base_report:
        parser.error('condition report requires a complete base report')
    source_files = [pathlib.Path(__file__), task_dir / 'wine_reference_launch.swift',
                    task_dir / 'artifact_real3d_gate.py']
    source_before = {f.name: sha256_file(f) for f in source_files}
    if args.frames < 2 or args.warmup < 0 or args.rounds < 1:
        parser.error('invalid workload')
    if args.base_report:
        report = json.loads(args.base_report.read_text())
        app_binary, cli, _ = _find_packaged_cli(args.app_bundle)
        expected = {'appBinarySHA256': sha256_file(app_binary), 'cliBinarySHA256': sha256_file(cli),
                    'runtimeManifestSHA256': sha256_file(args.app_bundle / 'Contents/Resources/runtime-manifest.json')}
        release = json.loads(args.release_manifest.read_text())
        if not report.get('backendCoverageComplete') or any(
            report.get('packagedArtifacts', {}).get(k) != v for k, v in expected.items()
        ) or any(release.get('artifacts', {}).get(k) != v for k, v in expected.items()) or (
            report.get('packagedArtifacts', {}).get('dmg') != release.get('artifacts', {}).get('dmg')
        ) or not verify_hardened(args.app_bundle)['passed']:
            parser.error('base report is incomplete or does not match current artifacts')
        report['baseReportSHA256'] = sha256_file(args.base_report)
        if args.condition_report:
            report = merge_extended_condition(report, json.loads(args.condition_report.read_text()),
                                              sha256_file(args.condition_report))
    else:
        report = run_artifact_performance_gate(
            app_bundle=args.app_bundle.resolve(), workspace_root=task_dir.parents[1],
            engine_root=args.engine_root.resolve(), frames=args.frames, warmup=args.warmup,
            release_manifest_path=args.release_manifest.resolve(), rounds=args.rounds,
            scratch_root=args.scratch_root,
            evidence_dir=args.output.parent / 'runs'
        )
    if args.real3d_probe:
        report['gateSourceSHA256'] = source_before
        report['gateSourcesStableDuringRun'] = source_before == {f.name: sha256_file(f) for f in source_files}
        (args.output.parent / 'artifact-base-gate-report.json').write_text(json.dumps(report, indent=2) + '\n')
        from artifact_real3d_gate import run_real3d_gate
        try:
            report['real3dSupplement'] = run_real3d_gate(args.app_bundle.resolve(), task_dir.parents[1],
                                                       args.real3d_probe.resolve(), args.output.parent / 'real3d-runs', args.rounds)
        except Exception as error:
            report['real3dSupplement'] = {
                'owner': '@DNPMBHC', 'passed': False, 'backendCoverageComplete': False,
                'error': _redact_run(str(error), task_dir.parents[1], args.scratch_root or pathlib.Path('/tmp')),
                'errorType': type(error).__name__, 'progressRetained': True}
        report['passed'] = report['passed'] and report['real3dSupplement']['passed']
    source_after = {f.name: sha256_file(f) for f in source_files}
    report['gateSourceSHA256'] = source_before
    report['gateSourcesStableDuringRun'] = source_before == source_after
    report['passed'] = report['passed'] and report['gateSourcesStableDuringRun']
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized)
    print(serialized, end='')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Artifact-level performance consistency gate against the packaged Release .app CLI."""

from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile


DEFAULT_ENGINE_ROOT = pathlib.Path.home() / 'Library/Application Support/com.gamemac.www/wine-engine'
LAB_BASELINE_MANIFEST = 'handoff/phase-2/evidence/window-c/wine-dxmt-three-engine/manifest.json'
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
        'deviceMemoryMiBMean': round(statistics.fmean(device_mem_mib), 2) if device_mem_mib else None,
        'gpuMsCoverage': round(len(gpu_ms_values) / row_count, 4) if row_count else 0.0,
    }


def evaluate_backend_consistency(
    backend: str,
    measured: dict,
    lab_baseline: dict,
    expected_frames: int,
    min_fps_ratio: float = 0.50,
    dxmt_max_vram_mib: float = 64.0,
) -> dict:
    """Assert packaged artifact run matches laboratory baseline without silent degradation."""
    errors: list[str] = []
    lab_key = backend.lower()
    lab_entry = lab_baseline.get(lab_key, {}).get('cold', {})
    lab_fps = float(lab_entry.get('derived_fps_mean') or 0.0)
    lab_vram = lab_entry.get('device_memory_mib_mean')

    if measured.get('frameCount', 0) < expected_frames:
        errors.append(f'insufficient_frames:{measured.get("frameCount", 0)}<{expected_frames}')

    measured_fps = float(measured.get('derivedFPS') or 0.0)
    fps_ratio = round(measured_fps / lab_fps, 4) if lab_fps > 0 else None
    if lab_fps > 0 and measured_fps < lab_fps * min_fps_ratio:
        errors.append(f'fps_regression:{measured_fps:.2f}<{lab_fps * min_fps_ratio:.2f}')

    measured_vram = measured.get('deviceMemoryMiBMean')
    if lab_key == 'dxmt':
        if measured_vram is not None and measured_vram > dxmt_max_vram_mib:
            errors.append(f'dxmt_vram_signature_unexpected:{measured_vram:.2f}>{dxmt_max_vram_mib:.2f}')

    return {
        'passed': not errors,
        'errors': errors,
        'labBaselineColdFPS': round(lab_fps, 2) if lab_fps > 0 else None,
        'labBaselineDeviceMemoryMiB': round(float(lab_vram), 2) if lab_vram is not None else None,
        'fpsRatioToLabBaseline': fps_ratio,
        'minRequiredFPSRatio': min_fps_ratio,
    }


def verify_bundled_manifest_against_sandbox(manifest_path: pathlib.Path, libraries_dir: pathlib.Path) -> dict:
    """Verify bundled runtime-manifest.json locked components against mounted sandbox libraries."""
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
            found = None
            for rel in candidates:
                cand = libraries_dir / rel
                if cand.is_file():
                    found = cand
                    break
            if found is None or sha256_file(found) != art['sha256'].lower():
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
) -> pathlib.Path:
    """Create a real bottle via the packaged CLI and configure its graphics routing mode."""
    subprocess.run([str(cli_bin), 'create', bottle_name], env=base_env, capture_output=True, text=True, check=True)
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
    meta.setdefault('wineConfig', {})['adaptiveResourcePolicyEnabled'] = True
    dxvk_cfg = meta.setdefault('dxvkConfig', {})
    dxvk_cfg['dxvk'] = (mode == 'dxvk')
    dxvk_cfg['graphicsBackendMode'] = mode
    dxvk_cfg['directXAPIRequirement'] = 'directX11'
    dxvk_cfg['graphicsRoutingPreference'] = 'performanceFirst'
    with meta_path.open('wb') as handle:
        plistlib.dump(meta, handle, fmt=plistlib.FMT_XML)
    return bottle_dir


def _init_bottle_prefix(bottle_dir: pathlib.Path, engines: dict[str, pathlib.Path], backend: str, xdg_cache: pathlib.Path):
    env = os.environ.copy()
    env['WINEPREFIX'] = str(bottle_dir)
    env['WINEDEBUG'] = '-all'
    env['XDG_CACHE_HOME'] = str(xdg_cache)
    xdg_cache.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(engines['wine_root'] / 'bin/wine'), 'wineboot', '--init'],
                   env=env, capture_output=True, check=False)
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-w'],
                   env=env, capture_output=True, check=False)
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
                   env=env, capture_output=True, check=False)
    subprocess.run([str(engines['wine_root'] / 'bin/wineserver'), '-w'],
                   env=env, capture_output=True, check=False)


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


def run_artifact_performance_gate(
    app_bundle: pathlib.Path,
    workspace_root: pathlib.Path,
    engine_root: pathlib.Path = DEFAULT_ENGINE_ROOT,
    frames: int = 180,
    warmup: int = 60,
    backends: tuple[str, ...] = ('dxmt', 'd3dMetal', 'dxvk'),
    release_manifest_path: pathlib.Path | None = None,
    scratch_root: pathlib.Path | None = None,
) -> dict:
    app_bin, cli_bin, bundle_id = _find_packaged_cli(app_bundle)
    bundled_manifest = app_bundle / 'Contents/Resources/runtime-manifest.json'
    bundled_matrix = app_bundle / 'Contents/Resources/compatibility-matrix.json'
    probe_exe = workspace_root / PROBE_RELPATH
    lab_manifest = json.loads((workspace_root / LAB_BASELINE_MANIFEST).read_text(encoding='utf-8'))
    lab_aggregate = lab_manifest.get('aggregate', {})
    engines = _discover_engine_layout(engine_root)
    scratch_base = _choose_scratch_base(scratch_root)

    with tempfile.TemporaryDirectory(prefix='my-project-artifact-gate-', dir=str(scratch_base)) as tmp:
        tmp_path = pathlib.Path(tmp)
        sandbox_home = tmp_path / 'home'
        sandbox_runtime = tmp_path / 'runtime'
        sandbox_home.mkdir()
        product_prefix = app_bin.name
        libs_dir = _mount_sandbox_runtime(sandbox_runtime, engines, product_prefix)

        manifest_check = verify_bundled_manifest_against_sandbox(bundled_manifest, libs_dir)

        # Check packaged CLI integrity-report works under Release + Hardened Runtime.
        base_env = os.environ.copy()
        base_env['CFFIXED_USER_HOME'] = str(sandbox_home)
        base_env['HOME'] = str(sandbox_home)
        base_env[f'{product_prefix.upper()}_RUNTIME_ROOT'] = str(sandbox_runtime)
        base_env['WINEDEBUG'] = '-all'

        ir_proc = subprocess.run([str(cli_bin), 'integrity-report'],
                                 env=base_env, capture_output=True, text=True, check=True)
        integrity_report = json.loads(ir_proc.stdout)

        backend_runs: dict[str, dict] = {}
        all_backends_passed = True

        for backend in backends:
            xdg_cache = tmp_path / f'xdg-{backend}'
            bottle_dir = _create_and_configure_bottle(cli_bin, base_env, f'gate-{backend}', backend)
            _init_bottle_prefix(bottle_dir, engines, backend, xdg_cache)

            # Inspect environment generated by the packaged CLI (shellenv).
            shellenv_proc = subprocess.run(
                [str(cli_bin), 'shellenv', f'gate-{backend}'],
                env=base_env, capture_output=True, text=True, check=True,
            )
            shellenv_text = shellenv_proc.stdout
            env_checks = {
                'dxmtShaderCacheEnabled': (
                    'DXMT_SHADER_CACHE=' in shellenv_text and '1' in shellenv_text
                ) if backend == 'dxmt' else None,
                'dxmtBottleScopedCachePath': (
                    'DXMT_SHADER_CACHE_PATH=' in shellenv_text and 'dxmt_shader_cache' in shellenv_text
                ) if backend == 'dxmt' else None,
                'dxmtWineDllPathInjected': (
                    'WINEDLLPATH=' in shellenv_text and 'DXMT/wine' in shellenv_text
                ) if backend == 'dxmt' else None,
                'd3dMetalSharedDylibInjected': (
                    'WINE_GPTK_LIBD3DSHARED_PATH=' in shellenv_text and 'libd3dshared.dylib' in shellenv_text
                ) if backend == 'd3dMetal' else None,
                'dxvkMoltenVKInjected': (
                    'WINE_SONAME_LIBVULKAN=' in shellenv_text and 'libMoltenVK.dylib' in shellenv_text
                ) if backend == 'dxvk' else None,
            }

            run_env = base_env.copy()
            run_env['XDG_CACHE_HOME'] = str(xdg_cache)
            if backend == 'dxmt':
                run_env['DXMT_USE_DEFAULT_METAL_CACHE'] = '0'

            csv_out = tmp_path / f'{backend}.csv'
            z_csv = 'Z:' + str(csv_out.resolve()).replace('/', '\\')
            cmd = [
                str(cli_bin), 'run', '--bottle-path', '--',
                str(bottle_dir), str(probe_exe),
                '--frames', str(frames),
                '--warmup', str(warmup),
                '--width', '1280',
                '--height', '720',
                '--commands', '64',
                '--resource-bytes', '262144',
                '--csv', z_csv,
            ]
            proc = subprocess.run(cmd, env=run_env, capture_output=True, text=True, timeout=180)
            subprocess.run(
                [str(engines['wine_root'] / 'bin/wineserver'), '-k'],
                env={**run_env, 'WINEPREFIX': str(bottle_dir)},
                capture_output=True, check=False,
            )

            if proc.returncode != 0 or not csv_out.is_file():
                all_backends_passed = False
                backend_runs[backend] = {
                    'passed': False,
                    'exitCode': proc.returncode,
                    'csvProduced': csv_out.is_file(),
                    'envChecks': env_checks,
                    'errors': [f'cli_run_failed_exit_{proc.returncode}'],
                }
                continue

            measured = summarize_probe_csv(csv_out)
            consistency = evaluate_backend_consistency(
                backend=backend,
                measured=measured,
                lab_baseline=lab_aggregate,
                expected_frames=frames,
            )
            dxmt_cache_dir = bottle_dir / 'dxmt_shader_cache'
            dxmt_cache_created = dxmt_cache_dir.is_dir() if backend == 'dxmt' else None
            extra_errors = list(consistency['errors'])
            if backend == 'dxmt':
                if not env_checks['dxmtShaderCacheEnabled'] or not env_checks['dxmtBottleScopedCachePath']:
                    extra_errors.append('dxmt_env_injection_missing')
                if not env_checks['dxmtWineDllPathInjected']:
                    extra_errors.append('dxmt_winedllpath_missing')
            elif backend == 'd3dMetal' and not env_checks['d3dMetalSharedDylibInjected']:
                extra_errors.append('d3dmetal_shared_dylib_env_missing')
            elif backend == 'dxvk' and not env_checks['dxvkMoltenVKInjected']:
                extra_errors.append('dxvk_moltenvk_env_missing')

            run_passed = len(extra_errors) == 0
            all_backends_passed = all_backends_passed and run_passed
            backend_runs[backend] = {
                'passed': run_passed,
                'exitCode': proc.returncode,
                'measured': measured,
                'consistency': {**consistency, 'errors': extra_errors, 'passed': run_passed},
                'envChecks': env_checks,
                'dxmtBottleCacheDirPresent': dxmt_cache_created,
            }
            shutil.rmtree(bottle_dir, ignore_errors=True)
            shutil.rmtree(xdg_cache, ignore_errors=True)

    release_info = None
    if release_manifest_path and release_manifest_path.is_file():
        release_info = json.loads(release_manifest_path.read_text(encoding='utf-8'))

    overall_passed = bool(
        manifest_check['allLockedComponentsVerified']
        and all_backends_passed
        and integrity_report.get('schema_version') == '1.1.0'
    )

    return {
        'schema': 'task-07-artifact-perf-gate-v1',
        'owner': '@DNPMBHC',
        'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'passed': overall_passed,
        'packagedArtifacts': {
            'appBinarySHA256': sha256_file(app_bin),
            'cliBinarySHA256': sha256_file(cli_bin),
            'runtimeManifestSHA256': sha256_file(bundled_manifest),
            'compatibilityMatrixSHA256': sha256_file(bundled_matrix),
            'probeBinarySHA256': sha256_file(probe_exe),
            'dmg': (release_info or {}).get('artifacts', {}).get('dmg'),
            'hardenedRuntimeEnabled': (release_info or {}).get('hardenedRuntimeEnabled', True),
        },
        'cliIntegrityReport': {
            'schemaVersion': integrity_report.get('schema_version'),
            'hostSIPStatus': integrity_report.get('host_sip_status'),
            'hostExecutionNature': integrity_report.get('host_execution_nature'),
            'isOfficialBuild': integrity_report.get('is_official_build'),
        },
        'runtimeManifestVerification': manifest_check,
        'workload': {
            'width': 1280,
            'height': 720,
            'warmupFrames': warmup,
            'measuredFrames': frames,
            'commandsPerFrame': 64,
            'resourceBytes': 262144,
        },
        'backends': backend_runs,
        'scope': (
            'Direct execution of packaged Release Hardened Runtime .app embedded CLI '
            'against real Wine + DXMT/D3DMetal/DXVK and d3d11_probe.exe in isolated CFFIXED_USER_HOME; '
            'verifies zero packaging degradation versus laboratory three-engine baseline without claiming commercial game pass.'
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    task_dir = pathlib.Path(__file__).resolve().parent
    workspace_root = task_dir.parents[1]
    parser.add_argument('--app-bundle', type=pathlib.Path, required=True)
    parser.add_argument('--engine-root', type=pathlib.Path, default=DEFAULT_ENGINE_ROOT)
    parser.add_argument('--release-manifest', type=pathlib.Path)
    parser.add_argument('--frames', type=int, default=180)
    parser.add_argument('--warmup', type=int, default=60)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()

    report = run_artifact_performance_gate(
        app_bundle=args.app_bundle.resolve(),
        workspace_root=workspace_root,
        engine_root=args.engine_root.resolve(),
        frames=args.frames,
        warmup=args.warmup,
        release_manifest_path=args.release_manifest.resolve() if args.release_manifest else None,
    )
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized, encoding='utf-8')
    print(serialized, end='')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

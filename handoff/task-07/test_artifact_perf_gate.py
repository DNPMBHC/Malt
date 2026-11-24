import hashlib
import copy
import json
import pathlib
import tempfile
import unittest
import sys
import plistlib
from unittest import mock

from artifact_perf_gate import (
    evaluate_backend_consistency,
    summarize_probe_csv,
    verify_bundled_manifest_against_sandbox,
    evaluate_paired_runs,
    mapped_libraries_from_listing,
    parse_shell_environment,
    run_probe,
    run_mapped_probe,
    probe_process_ids,
    configure_probe_environment,
    aggregate_paired_runs,
    aggregate_gpu_runs,
    remove_isolated_directory,
    isolated_temporary_directory,
    merge_extended_condition,
    runtime_path_matches,
)


class ArtifactPerfGateTests(unittest.TestCase):
    def test_summarize_probe_csv_computes_fps_percentiles_and_vram(self):
        with tempfile.TemporaryDirectory(prefix='artifact-gate-test-') as tmp:
            csv_path = pathlib.Path(tmp) / 'sample.csv'
            csv_path.write_text(
                'frame,frame_interval_ms,device_memory_bytes,gpu_ms\n'
                '0,2.5,20971520,2.0\n'
                '1,3.0,20971520,2.2\n'
                '2,2.0,20971520,\n',
                encoding='utf-8',
            )
            summary = summarize_probe_csv(csv_path)
            self.assertEqual(summary['frameCount'], 3)
            self.assertEqual(summary['derivedFPS'], 400.0)
            self.assertEqual(summary['deviceMemoryMiBMean'], 20.0)
            self.assertAlmostEqual(summary['gpuMsCoverage'], 0.6667, places=4)

    def test_consistency_gate_flags_fps_regression_and_dxmt_vram_degradation(self):
        lab = {
            'dxmt': {'cold': {'derived_fps_mean': 360.0, 'device_memory_mib_mean': 20.15}},
            'dxvk': {'cold': {'derived_fps_mean': 320.0, 'device_memory_mib_mean': 223.72}},
        }
        good = evaluate_backend_consistency(
            'dxmt',
            {'frameCount': 180, 'derivedFPS': 340.0, 'deviceMemoryMiBMean': 20.0},
            lab,
            expected_frames=180,
        )
        self.assertTrue(good['passed'])

        regressed = evaluate_backend_consistency(
            'dxmt',
            {'frameCount': 180, 'derivedFPS': 90.0, 'deviceMemoryMiBMean': 220.0},
            lab,
            expected_frames=180,
        )
        self.assertFalse(regressed['passed'])
        self.assertTrue(any(err.startswith('fps_regression:') for err in regressed['errors']))
        self.assertTrue(any(err.startswith('dxmt_vram_signature_unexpected:') for err in regressed['errors']))

    def test_bundled_manifest_verifier_rejects_tampered_binary(self):
        with tempfile.TemporaryDirectory(prefix='artifact-manifest-test-') as tmp:
            root = pathlib.Path(tmp)
            libs = root / 'Libraries'
            target = libs / 'DXMT/wine/x86_64-unix/winemetal.so'
            target.parent.mkdir(parents=True)
            target.write_bytes(b'original-bytes')
            good_sha = hashlib.sha256(target.read_bytes()).hexdigest()

            manifest_path = root / 'runtime-manifest.json'
            manifest_path.write_text(
                json.dumps({
                    'schemaVersion': '1.0.0',
                    'components': [
                        {
                            'id': 'dxmt',
                            'version': 'v0.80',
                            'status': 'locked',
                            'artifacts': [
                                {'name': 'winemetal.so', 'relativePath': 'DXMT/wine/x86_64-unix/winemetal.so', 'sha256': good_sha}
                            ],
                        },
                        {'id': 'kosmicKrisp', 'version': 'reserved', 'status': 'reserved', 'artifacts': []},
                    ],
                }),
                encoding='utf-8',
            )
            ok = verify_bundled_manifest_against_sandbox(manifest_path, libs)
            self.assertTrue(ok['allLockedComponentsVerified'])

            target.write_bytes(b'tampered-bytes')
            bad = verify_bundled_manifest_against_sandbox(manifest_path, libs)
            self.assertFalse(bad['allLockedComponentsVerified'])

    def test_four_way_kosmickrisp_and_metalfx_consistency_assertions(self):
        lab = {
            'dxmt': {'cold': {'derived_fps_mean': 520.0, 'device_memory_mib_mean': 20.0}},
            'dxmt_metalfx_quality': {'cold': {'derived_fps_mean': 400.0, 'device_memory_mib_mean': 49.5}},
            'dxvk_kosmickrisp': {'cold': {'derived_fps_mean': 390.0, 'device_memory_mib_mean': 350.0}},
        }
        kk_ok = evaluate_backend_consistency(
            'dxvk_kosmickrisp',
            {'frameCount': 180, 'derivedFPS': 350.0, 'deviceMemoryMiBMean': 345.0},
            lab,
            expected_frames=180,
        )
        self.assertTrue(kk_ok['passed'])
        # If KosmicKrisp silently fell back to MoltenVK (~223 MiB), signature check must fail.
        kk_fallback = evaluate_backend_consistency(
            'dxvk_kosmickrisp',
            {'frameCount': 180, 'derivedFPS': 350.0, 'deviceMemoryMiBMean': 223.7},
            lab,
            expected_frames=180,
        )
        self.assertFalse(kk_fallback['passed'])
        self.assertTrue(any('kosmickrisp_vram_signature_unexpected' in e for e in kk_fallback['errors']))

        fx_ok = evaluate_backend_consistency(
            'dxmt_metalfx_quality',
            {'frameCount': 180, 'derivedFPS': 400.0, 'deviceMemoryMiBMean': 49.5},
            lab,
            expected_frames=180,
        )
        self.assertTrue(fx_ok['passed'])

    def test_missing_historical_baseline_cannot_claim_consistency(self):
        result = evaluate_backend_consistency('dxmt', {'derivedFPS': 400, 'frameCount': 180}, {}, 180)
        self.assertFalse(result['passed'])
        self.assertIn('historical_baseline_missing', result['errors'])

    def test_paired_gate_requires_reference_and_gpu_evidence(self):
        sample = {'derivedFPS': 400, 'frameIntervalP95Ms': 3, 'gpuMsMean': 2,
                  'gpuMsCoverage': 1, 'deviceMemoryMiBMean': 20}
        self.assertTrue(evaluate_paired_runs(sample, sample, 'dxmt')['passed'])
        self.assertFalse(evaluate_paired_runs(sample, {}, 'dxmt')['passed'])
        missing = {**sample, 'gpuMsMean': None, 'gpuMsCoverage': 0}
        self.assertFalse(evaluate_paired_runs(sample, missing, 'dxmt')['passed'])
        self.assertTrue(evaluate_paired_runs(missing, missing, 'd3dMetal')['passed'])
        slower = {**sample, 'derivedFPS': 330, 'frameIntervalP95Ms': 4.1}
        self.assertFalse(evaluate_paired_runs(slower, sample, 'dxmt')['passed'])

    def test_mapping_proof_requires_exact_locked_bytes(self):
        with tempfile.TemporaryDirectory(prefix='demo-app-mapping-test-') as tmp:
            root = pathlib.Path(tmp)
            expected = root / 'expected' / 'driver.dylib'
            loaded = root / 'loaded' / 'driver.dylib'
            expected.parent.mkdir()
            loaded.parent.mkdir()
            expected.write_bytes(b'locked-runtime')
            loaded.write_bytes(b'wrong-runtime')
            self.assertEqual(mapped_libraries_from_listing('n' + str(loaded), {'driver': expected}), {})
            loaded.write_bytes(expected.read_bytes())
            proof = mapped_libraries_from_listing('n' + str(loaded), {'driver': expected})
            self.assertEqual(proof['driver']['sha256'], hashlib.sha256(expected.read_bytes()).hexdigest())
            self.assertEqual(mapped_libraries_from_listing('', {'driver': expected}), {})

    def test_environment_parser_rejects_substring_false_positive(self):
        values = parse_shell_environment("export DXMT_METALFX_SPATIAL_SWAPCHAIN='0'\n"
                                         "export DXMT_CONFIG='factor=1.5;other=1'")
        self.assertEqual(values['DXMT_METALFX_SPATIAL_SWAPCHAIN'], '0')
        self.assertEqual(values['DXMT_CONFIG'], 'factor=1.5;other=1')

    def test_probe_timeout_returns_failure_with_captured_output(self):
        result = run_probe([sys.executable, '-u', '-c',
                            "import time; print('started'); time.sleep(10)"], {}, timeout=0.2)
        self.assertEqual(result.returncode, 124)
        self.assertIn('started', result.stdout)
        self.assertIn('probe_timeout', result.stderr)

    def test_orphaned_wine_probe_requires_unique_csv_marker(self):
        rows = ['10 1 cli run --csv Z:unique.csv', '11 10 wine-start',
                '12 1 probe.exe --csv Z:unique.csv', '13 1 probe.exe --csv Z:other.csv',
                '14 12 renderer', 'unparseable']
        self.assertEqual(probe_process_ids(rows, 10, 'Z:unique.csv'), {10, 11, 12, 14})

    def test_file_capture_keeps_large_output_and_child_output(self):
        result = run_probe([sys.executable, '-u', '-c',
                            "import os; os.write(1,b'x'*262144); os.write(2,b'y'*262144)"], {}, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'x' * 262144)
        self.assertEqual(result.stderr, 'y' * 262144)

    def test_mapping_observation_does_not_block_verbose_child(self):
        def observe(process, marker, libraries):
            process.wait(timeout=5)
            return {}

        with mock.patch('artifact_perf_gate.observe_probe_mappings', side_effect=observe):
            code, stdout, stderr, mapped = run_mapped_probe(
                [sys.executable, '-u', '-c', "import os; os.write(2,b'x'*262144)"], {}, {})
        self.assertEqual(code, 0)
        self.assertEqual(stderr, 'x' * 262144)
        self.assertEqual(mapped, {})

    def test_program_environment_uses_canonical_identity_and_exact_values(self):
        with tempfile.TemporaryDirectory(prefix='demo-app-environment-test-') as tmp:
            root = pathlib.Path(tmp)
            probe = root / 'probe.exe'
            probe.write_bytes(b'probe')
            overrides = {'DXMT_SHADER_CACHE_PATH': '/isolated/cache', 'DXMT_METALFX_SPATIAL_SWAPCHAIN': '0'}
            path = configure_probe_environment(root / 'bottle', probe, overrides)
            digest = hashlib.sha256(str(probe.resolve()).encode()).hexdigest()
            self.assertEqual(path.name, 'v2-' + digest + '.plist')
            self.assertEqual(plistlib.loads(path.read_bytes())['environment'], overrides)
            self.assertEqual(plistlib.loads(path.read_bytes())['locale'], '')
            self.assertEqual(plistlib.loads(path.read_bytes())['arguments'], '')

    def test_condition_mean_uses_every_round_and_rejects_systematic_regression(self):
        baseline = {'frameCount': 900, 'derivedFPS': 400, 'frameIntervalP95Ms': 3,
                    'deviceMemoryMiBMean': 20}
        samples = [{'artifact': {**baseline, 'derivedFPS': fps}, 'reference': baseline}
                   for fps in [300, 400, 400]]
        result = aggregate_paired_runs(samples, 'dxmt', 900)
        self.assertTrue(result['passed'])
        self.assertAlmostEqual(result['artifact']['derivedFPS'], 1100 / 3)
        self.assertEqual(result['roundCount'], 3)
        for sample in samples:
            sample['artifact']['derivedFPS'] = 330
        self.assertFalse(aggregate_paired_runs(samples, 'dxmt', 900)['passed'])
        samples[0]['artifact']['frameCount'] = 899
        self.assertIn('incomplete_paired_frames', aggregate_paired_runs(samples, 'dxmt', 900)['errors'])

    def test_native_identity_digest_controls_program_settings_filename(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            native = 'a' * 64
            with mock.patch('artifact_perf_gate.subprocess.run', return_value=mock.Mock(stdout=native)) as run:
                path = configure_probe_environment(root / 'bottle', root / 'probe.exe', {'VALUE': 'exact'}, root / 'helper')
            self.assertEqual(path.name, 'v2-' + native + '.plist')
            self.assertEqual(plistlib.loads(path.read_bytes())['environment'], {'VALUE': 'exact'})
            self.assertEqual(run.call_args.args[0][1], '--identity-digest')

    def test_portable_identity_matches_relative_program_inside_bottle(self):
        with tempfile.TemporaryDirectory() as tmp:
            bottle = pathlib.Path(tmp)
            executable = bottle / 'drive_c' / 'probe.exe'
            path = configure_probe_environment(bottle, executable, {})
            expected = hashlib.sha256(b'drive_c/probe.exe').hexdigest()
            self.assertEqual(path.name, 'v2-' + expected + '.plist')

    def test_bundled_icd_accepts_file_alias_and_rejects_different_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            target, alias, other = root / 'icd.json', root / 'alias.json', root / 'other.json'
            target.write_text('locked')
            other.write_text('locked')
            alias.symlink_to(target)
            self.assertTrue(runtime_path_matches(str(alias), target))
            self.assertFalse(runtime_path_matches(str(other), target))
            self.assertFalse(runtime_path_matches(None, target))

    def gpu_rounds(self, times):
        reference = {'frameCount': 120, 'derivedFPS': 400, 'frameIntervalP95Ms': 3,
                     'deviceMemoryMiBMean': 20, 'gpuMsMean': 1, 'gpuMsCoverage': 1}
        return [{'round': index + 1, 'artifact': {**reference, 'gpuMsMean': value},
                 'reference': reference.copy(), 'driverMappingRequired': True, 'driverMappingVerified': True,
                 'pairedConsistency': evaluate_paired_runs({**reference, 'gpuMsMean': value}, reference, 'dxvk')}
                for index, value in enumerate(times)]

    def test_gpu_mean_preserves_outlier_and_rejects_systematic_regression(self):
        samples = self.gpu_rounds([1.6, 1.1, 1.1])
        result = aggregate_gpu_runs(samples, 'dxvk', 3)
        self.assertTrue(result['passed'])
        self.assertEqual(result['rawPerformanceOutlierCount'], 1)
        self.assertAlmostEqual(result['artifact']['gpuMsMean'], 3.8 / 3)
        self.assertEqual(result['runs'], samples)
        self.assertFalse(aggregate_gpu_runs(self.gpu_rounds([1.31, 1.31, 1.31]), 'dxvk', 3)['passed'])

    def test_gpu_mean_requires_each_round_mapping_timestamps_and_complete_frames(self):
        samples = self.gpu_rounds([1, 1, 1])
        self.assertFalse(aggregate_gpu_runs(samples[:2], 'dxvk', 3)['passed'])
        samples[0]['driverMappingVerified'] = False
        self.assertIn('gpu_round_locked_mapping_missing', aggregate_gpu_runs(samples, 'dxvk', 3)['pairedConsistency']['errors'])
        samples[0]['driverMappingVerified'] = True
        samples[0]['artifact']['gpuMsCoverage'] = 0.94
        self.assertFalse(aggregate_gpu_runs(samples, 'dxvk', 3)['passed'])
        samples[0]['artifact']['gpuMsCoverage'] = 1
        samples[0]['artifact']['frameCount'] = 119
        self.assertFalse(aggregate_gpu_runs(samples, 'dxvk', 3)['passed'])
        samples[0]['artifact']['frameCount'] = 120
        samples[0]['artifact'].pop('gpuMsMean')
        self.assertFalse(aggregate_gpu_runs(samples, 'dxvk', 3)['passed'])

    def test_isolated_cleanup_retries_transient_writer_and_reports_permanent_failure(self):
        with mock.patch('artifact_perf_gate.shutil.rmtree', side_effect=[OSError('busy'), None]) as remove, \
                mock.patch('artifact_perf_gate.time.sleep'):
            remove_isolated_directory(pathlib.Path('/isolated/example'))
            self.assertEqual(remove.call_count, 2)
        with mock.patch('artifact_perf_gate.shutil.rmtree', side_effect=OSError('busy')), \
                mock.patch('artifact_perf_gate.time.sleep'):
            with self.assertRaises(OSError):
                remove_isolated_directory(pathlib.Path('/isolated/example'))

    def test_cleanup_failure_keeps_original_run_failure(self):
        with tempfile.TemporaryDirectory() as parent:
            with mock.patch('artifact_perf_gate.remove_isolated_directory', side_effect=OSError('busy')):
                with self.assertRaisesRegex(ValueError, 'run_failed') as failure:
                    with isolated_temporary_directory(prefix='demo-app-test-', dir=parent):
                        raise ValueError('run_failed')
            self.assertIn('isolated_temporary_directory_cleanup_failed', failure.exception.__notes__)

    def revision_fixture(self):
        sample = {'frameCount': 9000, 'derivedFPS': 400, 'frameIntervalP95Ms': 3,
                  'deviceMemoryMiBMean': 20, 'gpuMsMean': 1, 'gpuMsCoverage': 1}
        gpu = self.gpu_rounds([1, 1, 1])
        for item in gpu:
            item['actualMappedLibraries'] = {'driver': {'filename': 'driver.dylib', 'sha256': 'a' * 64}}
        measured = {'passed': True, 'envChecks': {'selected': True}, 'gpuValidation': aggregate_gpu_runs(gpu, 'dxvk', 3),
                    'runs': [{'round': index, 'cacheState': state, 'artifact': sample.copy(), 'reference': sample.copy(),
                              'errors': [], 'integrityPassed': True}
                             for index in range(1, 4) for state in ('cold', 'hot')]}
        common = {'packagedArtifacts': {key: 'a' * 64 for key in
                                       ('appBinarySHA256', 'cliBinarySHA256', 'runtimeManifestSHA256', 'probeBinarySHA256', 'dmg')},
                  'hardenedRuntimeVerification': {'passed': True}, 'releaseManifestMatchesArtifacts': True,
                  'runtimeManifestVerification': {'allLockedComponentsVerified': True},
                  'vulkanFeatureProbe': {'geometryShader': True, 'fillModeNonSolid': True},
                  'gateSourceSHA256': {'gate.py': 'b' * 64}, 'gateSourcesStableDuringRun': True}
        base = {**copy.deepcopy(common), 'backendCoverageComplete': True, 'workload': {'measuredFrames': 900, 'rounds': 3},
                'backends': {'case-' + str(index): {'passed': True} for index in range(4)},
                'real3dSupplement': {'passed': True}}
        base['backends']['dxvk_compat'] = {**copy.deepcopy(measured), 'passed': False}
        replacement = {**copy.deepcopy(common), 'workload': {'measuredFrames': 9000, 'rounds': 3},
                       'backends': {'dxvk_compat': measured}}
        return base, replacement

    def test_extended_condition_preserves_failed_result_and_declares_per_condition_frames(self):
        base, replacement = self.revision_fixture()
        merged = merge_extended_condition(base, replacement, 'c' * 64)
        self.assertTrue(merged['passed'])
        self.assertFalse(merged['measurementRevisions'][0]['previousResult']['passed'])
        self.assertFalse(base['backends']['dxvk_compat']['passed'])
        self.assertEqual(merged['workload']['measurementFramesByCondition']['dxvk_compat'], 9000)
        self.assertEqual(merged['workload']['measurementFramesByCondition']['case-0'], 900)

    def test_extended_condition_rejects_changed_artifacts_sources_frames_and_mapping(self):
        for mutate in [lambda d: d['packagedArtifacts'].update(cliBinarySHA256='d' * 64),
                       lambda d: d['gateSourceSHA256'].update({'gate.py': 'd' * 64}),
                       lambda d: d['backends']['dxvk_compat']['runs'].pop(),
                       lambda d: d['backends']['dxvk_compat']['runs'][0]['artifact'].update(frameCount=8999),
                       lambda d: d['backends']['dxvk_compat']['gpuValidation']['runs'][0]['actualMappedLibraries'].clear()]:
            base, replacement = self.revision_fixture()
            mutate(replacement)
            with self.assertRaises(ValueError):
                merge_extended_condition(base, replacement, 'c' * 64)

    def test_extended_condition_cannot_promote_performance_or_unrelated_failure(self):
        base, replacement = self.revision_fixture()
        for run in replacement['backends']['dxvk_compat']['runs']:
            run['artifact']['derivedFPS'] = 330
        self.assertFalse(merge_extended_condition(base, replacement, 'c' * 64)['passed'])
        base, replacement = self.revision_fixture()
        base['backends']['case-0']['passed'] = False
        self.assertFalse(merge_extended_condition(base, replacement, 'c' * 64)['passed'])


if __name__ == '__main__':
    unittest.main()

import hashlib
import json
import pathlib
import tempfile
import unittest

from artifact_perf_gate import (
    evaluate_backend_consistency,
    summarize_probe_csv,
    verify_bundled_manifest_against_sandbox,
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


if __name__ == '__main__':
    unittest.main()

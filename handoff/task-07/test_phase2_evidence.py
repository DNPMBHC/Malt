import json
import pathlib
import tempfile
import unittest

from phase2_evidence import (
    is_valid_sha256_binding,
    requires_immutable_digest_binding,
    validate_phase2_evidence,
)


VALID_SHA = 'a' * 64
VALID_SHA_2 = 'b' * 64


class Phase2EvidenceValidatorTests(unittest.TestCase):
    def test_pending_windows_pass_locally_without_claiming_real_completion(self):
        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            (root / 'window-a').mkdir()
            (root / 'window-a/runtime-guest-configuration.template.json').write_text('{"id":"tmpl"}')
            report = validate_phase2_evidence(root)
            self.assertTrue(report['passed'])
            self.assertFalse(report['anyRealEvidencePresent'])
            self.assertFalse(report['allWindowsHaveRealEvidence'])
            self.assertEqual(report['windows']['window-a']['status'], 'pending_real_evidence')

    def test_real_evidence_missing_sha256_bindings_fails(self):
        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            (root / 'window-c').mkdir()
            payload = {
                'schema': 'performance-sample-v1',
                'realWineExecuted': True,
                'runs': [{'startup': 'cold', 'startupMs': 1200}],
            }
            (root / 'window-c/wine-bench.json').write_text(json.dumps(payload))
            report = validate_phase2_evidence(root)
            self.assertFalse(report['passed'])
            artifact = report['windows']['window-c']['artifacts'][0]
            self.assertIn('missing_or_invalid_sourceSHA256', artifact['errors'])
            self.assertIn('missing_or_invalid_binarySHA256', artifact['errors'])

    def test_real_evidence_with_valid_sha256_bindings_and_proposal_passes(self):
        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            for win, flag in (('window-a', 'realGuestExecuted'),
                              ('window-b', 'realDriverLoaded'),
                              ('window-c', 'realWineExecuted')):
                (root / win).mkdir()
                payload = {
                    'schema': 'phase2-real-v1',
                    flag: True if flag != 'realDriverLoaded' else 'passed',
                    'sourceSHA256': {'main.c': VALID_SHA},
                    'binarySHA256': VALID_SHA_2,
                }
                (root / win / 'result.json').write_text(json.dumps(payload))
            (root / 'window-c/interface-proposal.md').write_text('# proposal\n')
            report = validate_phase2_evidence(root)
            self.assertTrue(report['passed'])
            self.assertTrue(report['allWindowsHaveRealEvidence'])
            self.assertEqual(report['completedWindowCount'], 3)
            self.assertEqual(report['interfaceProposals'], ['window-c/interface-proposal.md'])

    def test_unredacted_home_path_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            (root / 'window-a').mkdir()
            payload = {
                'schema': 'phase2-real-v1',
                'realGuestExecuted': True,
                'sourceSHA256': VALID_SHA,
                'binarySHA256': VALID_SHA_2,
                'note': 'leaked /Users/alice/secret path',
            }
            (root / 'window-a/guest.json').write_text(json.dumps(payload))
            report = validate_phase2_evidence(root)
            self.assertFalse(report['passed'])
            self.assertIn('unredacted_home_path_detected', report['windows']['window-a']['artifacts'][0]['errors'])

    def test_sha256_helper_rejects_short_or_uppercase(self):
        self.assertTrue(is_valid_sha256_binding(VALID_SHA))
        self.assertFalse(is_valid_sha256_binding('a' * 63))
        self.assertFalse(is_valid_sha256_binding('A' * 64))
        self.assertFalse(is_valid_sha256_binding({}))
        self.assertTrue(requires_immutable_digest_binding({'kind': 'real-wdk-probe'}))

    def test_immutable_digests_map_requires_both_source_and_binary_entries(self):
        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            (root / 'window-c').mkdir()
            valid_manifest = {
                'experiment': 'wine_dxvk_vs_d3dmetal',
                'runs': [{'pass': 'dxvk-r1-cold'}],
                'immutable_digests': {
                    'd3d11_probe_cpp': VALID_SHA,
                    'd3d11_probe_exe': VALID_SHA_2,
                    'wine': VALID_SHA_2,
                },
            }
            (root / 'window-c/manifest.json').write_text(json.dumps(valid_manifest))
            report = validate_phase2_evidence(root)
            self.assertTrue(report['passed'])
            self.assertEqual(report['windows']['window-c']['status'], 'real_evidence_validated')

            source_only = {
                'experiment': 'wine_dxvk_vs_d3dmetal',
                'runs': [{'pass': 'dxvk-r1-cold'}],
                'immutable_digests': {'d3d11_probe_cpp': VALID_SHA},
            }
            (root / 'window-c/manifest.json').write_text(json.dumps(source_only))
            bad_report = validate_phase2_evidence(root)
            self.assertFalse(bad_report['passed'])
            self.assertIn(
                'missing_or_invalid_binarySHA256',
                bad_report['windows']['window-c']['artifacts'][0]['errors'],
            )

    def test_tampered_referenced_file_bytes_must_fail(self):
        import hashlib

        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            win_c = root / 'window-c'
            win_c.mkdir()
            csv_path = win_c / 'run1.csv'
            csv_path.write_text('frame,ms\n1,2.5\n', encoding='utf-8')
            good_sha = hashlib.sha256(csv_path.read_bytes()).hexdigest()
            manifest = {
                'experiment': 'wine_bench',
                'immutable_digests': {'probe_cpp': VALID_SHA, 'probe_exe': VALID_SHA_2},
                'runs': [{'files': {'csv': 'run1.csv', 'csv_sha256': good_sha}}],
            }
            (win_c / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')

            ok_report = validate_phase2_evidence(root)
            self.assertTrue(ok_report['passed'])
            self.assertEqual(ok_report['windows']['window-c']['verifiedEvidenceDigestCount'], 1)

            # Tamper a single byte in run1.csv -> digest mismatch must fail the gate.
            csv_path.write_text('frame,ms\n1,9.9\n', encoding='utf-8')
            tampered_report = validate_phase2_evidence(root)
            self.assertFalse(tampered_report['passed'])
            self.assertIn(
                'digest_mismatch:run1.csv',
                tampered_report['windows']['window-c']['artifacts'][0]['errors'],
            )

    def test_recognizes_window_a_b_c_latest_real_evidence_schemas(self):
        import hashlib

        with tempfile.TemporaryDirectory(prefix='task-07-p2-') as directory:
            root = pathlib.Path(directory)
            for name in ('window-a', 'window-b', 'window-c'):
                (root / name).mkdir()

            # Window A nested e2e + real interactive run
            (root / 'window-a/real-m0-gui.json').write_text(
                json.dumps({'realRunID': 'run-123', 'targetPID': 4100, 'exitCode': 0}),
                encoding='utf-8',
            )
            # Window B native ARM64 driver build + full lifecycle
            (root / 'window-b/b2-lifecycle-cycle-result.json').write_text(
                json.dumps({
                    'stage': 'lifecycle-cycle',
                    'exit_code': 0,
                    'stdout': '[{"loadState": "loaded"}, {"loadState": "notLoaded"}]',
                }),
                encoding='utf-8',
            )
            # Window C input_artifacts with real file digest match
            inputs_dir = root / 'window-c/inputs'
            inputs_dir.mkdir()
            src_file = inputs_dir / 'probe.cpp'
            bin_file = inputs_dir / 'probe.exe'
            src_file.write_bytes(b'int main(){return 0;}\n')
            bin_file.write_bytes(b'MZ\x90\x00')
            (root / 'window-c/manifest.json').write_text(
                json.dumps({
                    'kind': 'actual-dxgi-adapter-fingerprints',
                    'input_artifacts': {
                        'probe.cpp': {'file': 'inputs/probe.cpp', 'sha256': hashlib.sha256(src_file.read_bytes()).hexdigest()},
                        'probe.exe': {'file': 'inputs/probe.exe', 'sha256': hashlib.sha256(bin_file.read_bytes()).hexdigest()},
                    },
                    'runs': [{'environment': 'windows-guest'}],
                }),
                encoding='utf-8',
            )

            report = validate_phase2_evidence(root)
            self.assertTrue(report['passed'])
            self.assertEqual(report['completedWindowCount'], 3)
            self.assertIn('window-a-real-interactive', report['windows']['window-a']['realEvidenceKinds'])
            self.assertIn('window-b-native-driver-lifecycle', report['windows']['window-b']['realEvidenceKinds'])
            self.assertIn('window-c-benchmark-manifest', report['windows']['window-c']['realEvidenceKinds'])
            self.assertEqual(report['windows']['window-c']['verifiedEvidenceDigestCount'], 2)


if __name__ == '__main__':
    unittest.main()

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


if __name__ == '__main__':
    unittest.main()

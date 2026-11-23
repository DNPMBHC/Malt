#!/usr/bin/env python3
"""Local transfer/stage regressions. Every transport call is a mock."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).absolute().parent


def load(name, leaf):
    spec = importlib.util.spec_from_file_location(name, HERE / leaf)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


pull = load('b2_pull_checks', 'b2-pull-evidence.py')
stage = load('b2_stage_checks', 'b2-run-stage.py')
controller = load('b2_redactor_checks', 'b2-guest-control.py')


def completed(stdout='{}', **changes):
    value = {'exit_code': 0, 'signal': 0, 'stdout': stdout}
    value.update(changes)
    return value


class MockControl:
    def __init__(self):
        self.PRIVATE_TOKENS = {'fixture-person', 'fixture-box'}
        self.calls = []
        self.initialized = 0

    def initialize(self):
        self.initialized += 1

    def sanitize(self, value):
        with patch.object(controller, 'ROOT', None), patch.object(controller, 'PRIVATE_TOKENS', self.PRIVATE_TOKENS):
            return controller.sanitize(value)


class PullControl(MockControl):
    def __init__(self, data=b'{"result":"neutral"}', metadata=None, chunk=None):
        super().__init__()
        self.data = data
        self.metadata = metadata
        self.chunk = chunk
        self.metadata_reads = 0
        self.chunk_reads = []

    def powershell(self, code, timeout, label):
        self.calls.append(label)
        if label == 'evidence-file-metadata':
            index = self.metadata_reads
            self.metadata_reads += 1
            value = {'size': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}
            if self.metadata is not None:
                value = self.metadata(index, value)
            if isinstance(value, Exception):
                raise value
            if isinstance(value, dict) and any(key in value for key in ('exit_code', 'status', 'signal', 'stdout')):
                return value
            return completed(value if isinstance(value, str) else json.dumps(value))
        if label != 'bounded-evidence-read':
            raise AssertionError('An unmocked transport label was requested.')
        offset = int(re.search(r'Seek\((\d+),', code).group(1))
        count = int(re.search(r'new\((\d+)\)', code).group(1))
        self.chunk_reads.append((offset, count))
        if self.chunk is not None:
            value = self.chunk(offset, count)
            if isinstance(value, Exception):
                raise value
            if isinstance(value, dict):
                return value
            if isinstance(value, str):
                return completed(value)
        else:
            value = self.data[offset:offset + count]
        return completed(base64.b64encode(value).decode())


class StageControl(MockControl):
    def __init__(self, result=None, identity=None):
        super().__init__()
        self.result = completed() if result is None else result
        self.identity = completed(json.dumps({'a': 'fixture-box', 'b': 'fixture-domain' + chr(92) + 'fixture-person'})) if identity is None else identity

    def powershell(self, code, timeout, label):
        self.calls.append(label)
        value = self.identity if label == 'private-output-token-preparation' else self.result
        if isinstance(value, Exception):
            raise value
        return value


class TransferChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='b2-neutral-checks-')
        self.directory = Path(self.temporary.name)
        if pull.safety is None:
            pull.safety = pull.load_safety()
        if stage.safety is None:
            stage.safety = stage.load_safety()

    def tearDown(self):
        self.temporary.cleanup()

    def run_pull(self, control, leaf='source.json', alias='capture.json'):
        output = io.StringIO()
        with patch.object(pull, 'HERE', self.directory), patch.object(pull, 'load_control', return_value=control), contextlib.redirect_stdout(output):
            code = pull.main([leaf, alias])
        return code, json.loads(output.getvalue())

    def run_stage(self, control, extra=(), alias='sample-stage'):
        source = self.directory / 'neutral-source.ps1'
        source.write_bytes(b'[pscustomobject]@{status="captured"}|ConvertTo-Json\n')
        output = io.StringIO()
        with patch.object(stage, 'HERE', self.directory), patch.object(stage, 'load_control', return_value=control), contextlib.redirect_stdout(output):
            code = stage.main([alias, str(source), *extra])
        return code, json.loads(output.getvalue()), source

    def assert_no_capture(self):
        self.assertFalse((self.directory / 'capture.json').exists())
        self.assertFalse(any(path.suffix == '.tmp' for path in self.directory.iterdir()))

    def test_pull_exact_chunk_boundaries(self):
        for length in (1, 11999, 12000, 12001, 24000, 24001):
            with self.subTest(length=length):
                data = b'0' if length == 1 else json.dumps({'pad': 'x' * (length - 10)}, separators=(',', ':')).encode()
                self.assertEqual(len(data), length)
                control = PullControl(data)
                code, report = self.run_pull(control)
                self.assertEqual(code, 0)
                self.assertEqual(report['chunks'], (length + 11999) // 12000)
                self.assertEqual(control.metadata_reads, 2)
                self.assertTrue(all(0 < count <= 12000 for _, count in control.chunk_reads))
                content = (self.directory / 'capture.json').read_bytes()
                self.assertEqual(report['sanitized_sha256'], hashlib.sha256(content).hexdigest())

    def test_pull_short_reads_are_valid_and_counted(self):
        data = b'{"pad":"' + b'x' * 40 + b'"}'
        control = PullControl(data, chunk=lambda offset, count: data[offset:offset + min(count, 7)])
        code, report = self.run_pull(control)
        self.assertEqual(code, 0)
        self.assertEqual(report['chunks'], len(control.chunk_reads))
        self.assertGreater(report['chunks'], 1)

    def test_pull_utf8_bom_and_multibyte_boundary(self):
        data = b'\xef\xbb\xbf' + json.dumps({'note': '中文' * 2400}, ensure_ascii=False).encode()
        code, report = self.run_pull(PullControl(data))
        self.assertEqual(code, 0)
        self.assertEqual(report['source_size_bytes'], len(data))
        self.assertEqual(json.loads((self.directory / 'capture.json').read_text())['note'], '中文' * 2400)

    def test_pull_empty_chunk_fails_without_artifact(self):
        code, report = self.run_pull(PullControl(chunk=lambda offset, count: b''))
        self.assertEqual(code, 1)
        self.assertEqual(report['reason'], 'source_ended_before_recorded_size')
        self.assert_no_capture()

    def test_pull_invalid_base64_fails_without_artifact(self):
        code, report = self.run_pull(PullControl(chunk=lambda offset, count: '!!invalid!!'))
        self.assertEqual(code, 1)
        self.assertEqual(report['reason'], 'invalid_source_chunk_encoding')
        self.assert_no_capture()

    def test_pull_rejects_more_than_requested(self):
        code, report = self.run_pull(PullControl(chunk=lambda offset, count: b'x' * (count + 1)))
        self.assertEqual(code, 1)
        self.assertEqual(report['reason'], 'source_chunk_exceeds_requested_size')
        self.assert_no_capture()

    def test_pull_rejects_hash_mismatch(self):
        control = PullControl(metadata=lambda index, value: dict(value, sha256='0' * 64))
        code, report = self.run_pull(control)
        self.assertEqual(code, 1)
        self.assertEqual(report['reason'], 'source_hash_mismatch_during_transfer')
        self.assertEqual(control.metadata_reads, 1)
        self.assert_no_capture()

    def test_pull_rechecks_source_after_transfer(self):
        for changed in ('sha256', 'size'):
            with self.subTest(changed=changed):
                def metadata(index, value):
                    if index:
                        value[changed] = '0' * 64 if changed == 'sha256' else value['size'] + 1
                    return value
                code, report = self.run_pull(PullControl(metadata=metadata))
                self.assertEqual(code, 1)
                self.assertEqual(report['reason'], 'source_changed_after_transfer')
                self.assert_no_capture()

    def test_pull_size_validation_and_maximum(self):
        for value in (True, 1.5, '12', -1, 16000001):
            with self.subTest(size=value):
                control = PullControl(metadata=lambda index, metadata: dict(metadata, size=value))
                code, _ = self.run_pull(control)
                self.assertEqual(code, 1)
                self.assertEqual(control.chunk_reads, [])
        control = PullControl(metadata=lambda index, metadata: dict(metadata, size=16000000))
        self.assertEqual(pull.read_metadata(control, 'neutral')['size'], 16000000)
        self.assert_no_capture()

    def test_pull_metadata_hash_and_json_validation(self):
        for metadata in ({'size': 1, 'sha256': None}, {'size': 1, 'sha256': 'g' * 64}, [], '{partial'):
            with self.subTest(kind=type(metadata).__name__):
                code, _ = self.run_pull(PullControl(metadata=lambda index, value: metadata))
                self.assertEqual(code, 1)
                self.assert_no_capture()

    def test_pull_transport_failures_at_metadata_and_chunks(self):
        failures = (completed(exit_code=5), completed(signal=9), completed(status='timeout'), completed(stdout_truncated=True), {'stdout': '{}'})
        for failure in failures:
            for phase in ('metadata', 'chunk'):
                with self.subTest(phase=phase, status=failure.get('status')):
                    control = PullControl(metadata=(lambda index, value: failure) if phase == 'metadata' else None, chunk=(lambda offset, count: failure) if phase == 'chunk' else None)
                    code, _ = self.run_pull(control)
                    self.assertEqual(code, 124 if failure.get('status') == 'timeout' else 1)
                    self.assert_no_capture()

    def test_pull_rejects_empty_invalid_or_non_utf8_json(self):
        for data in (b'', b'{partial', b'\xff'):
            with self.subTest(size=len(data)):
                code, report = self.run_pull(PullControl(data))
                self.assertEqual(code, 1)
                self.assertEqual(report['reason'], 'invalid_source_json')
                self.assert_no_capture()

    def test_pull_sanitizes_known_identifiers_before_export(self):
        identifier = '-'.join(('a' * 8, 'b' * 4, 'c' * 4, 'd' * 4, 'e' * 12))
        payload = {'username': 'fixture-person', 'private_process_reference': 'fixture-ref', 'boundChildPID': 123, 'child_pid_matched': True, 'log': 'X:' + chr(92) + 'private-folder' + chr(92) + 'file.txt', 'id_note': identifier, 'network': '192.' + '0.2.1', 'mail': 'fixture' + '@' + 'example.invalid', 'name_note': 'fixture-box', 'version': '2.17.4.510'}
        code, _ = self.run_pull(PullControl(json.dumps(payload).encode()))
        self.assertEqual(code, 0)
        output = (self.directory / 'capture.json').read_text()
        for token in ('fixture-person', 'fixture-box', 'fixture-ref', 'private-folder', identifier, 'boundChildPID'):
            self.assertNotIn(token, output)
        self.assertTrue(json.loads(output)['child_pid_matched'])
        self.assertIn('2.17.4.510', output)

    def test_pull_blocks_residual_sensitive_fields_and_ipv6(self):
        for payload in ({'certificate_serial': 'opaque-fixture'}, {'stdout': json.dumps({'certificate_serial': 'opaque-fixture'})}, {'network': ':'.join(('2001', 'db8', '0', '0', '0', '0', '0', '1'))}):
            with self.subTest(payload_kind=next(iter(payload))):
                code, report = self.run_pull(PullControl(json.dumps(payload).encode()))
                self.assertEqual(code, 1)
                self.assertEqual(report['reason'], 'export_privacy_check_failed')
                self.assert_no_capture()

    def test_pull_failure_preserves_existing_artifact(self):
        target = self.directory / 'capture.json'
        target.write_bytes(b'previous-neutral-result')
        code, _ = self.run_pull(PullControl(chunk=lambda offset, count: b''))
        self.assertEqual(code, 1)
        self.assertEqual(target.read_bytes(), b'previous-neutral-result')

    def test_pull_atomic_failure_cleans_temporary_file(self):
        with patch.object(pull.safety.os, 'replace', side_effect=OSError('fixture-person confidential text')):
            code, report = self.run_pull(PullControl())
        self.assertEqual(code, 1)
        self.assertNotIn('confidential', json.dumps(report))
        self.assert_no_capture()

    def test_pull_replaces_target_symlink_without_following(self):
        original = self.directory / 'other-neutral.txt'
        original.write_text('unchanged')
        target = self.directory / 'capture.json'
        target.symlink_to(original)
        code, _ = self.run_pull(PullControl())
        self.assertEqual(code, 0)
        self.assertFalse(target.is_symlink())
        self.assertEqual(original.read_text(), 'unchanged')

    def test_pull_alias_validation_precedes_transport(self):
        for leaf, alias in (('../private.json', 'capture.json'), ('source.json', '../private.json'), ('source.json', 'Upper.json')):
            control = PullControl()
            code, _ = self.run_pull(control, leaf, alias)
            self.assertEqual(code, 1)
            self.assertEqual(control.initialized, 0)
            self.assertEqual(control.calls, [])

    def test_stage_success_records_source_fingerprint(self):
        code, report, source = self.run_stage(StageControl(completed('{"status":"captured"}')))
        self.assertEqual(code, 0)
        self.assertEqual(report['stage_source_sha256'], hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertEqual(report['wrapper_validation_status'], 'passed')
        self.assertEqual(json.loads((self.directory / 'b2-sample-stage-result.json').read_text()), report)

    def test_stage_nonzero_exit_signal_and_missing_status(self):
        for result in (completed(exit_code=7), completed(signal=9), {'stdout': '{}'}, completed(exit_code=False)):
            with self.subTest(exit_type=type(result.get('exit_code')).__name__):
                code, report, _ = self.run_stage(StageControl(result))
                self.assertEqual(code, 1)
                self.assertEqual(report['wrapper_validation_status'], 'failed')

    def test_stage_timeout_preserves_recovery_marker_without_handle(self):
        result = completed(status='timeout', exit_code=124, recovery_pending=True, private_process_reference='fixture-ref')
        code, report, _ = self.run_stage(StageControl(result))
        self.assertEqual(code, 124)
        self.assertTrue(report['recovery_pending'])
        self.assertNotIn('private_process_reference', report)
        self.assertNotIn('fixture-ref', json.dumps(report))

    def test_stage_all_truncation_markers_fail_and_discard_output(self):
        for key in stage.safety.TRUNCATION_KEYS:
            with self.subTest(marker=key):
                result = completed('unknown-fixture-output', **{key: True})
                code, report, _ = self.run_stage(StageControl(result))
                self.assertEqual(code, 1)
                self.assertEqual(report['stdout'], '')
                self.assertNotIn('unknown-fixture-output', json.dumps(report))

    def test_stage_native_and_reported_failure(self):
        for payload in ({'native_exit_code': 5}, {'native_exit_code': False}, {'status': 'failed'}, {'status': 'timeout'}):
            with self.subTest(kind=next(iter(payload))):
                code, report, _ = self.run_stage(StageControl(completed(json.dumps(payload))))
                self.assertEqual(code, 124 if payload.get('status') == 'timeout' else 1)
                self.assertEqual(report['wrapper_validation_status'], 'failed')

    def test_stage_requires_json_only_when_requested(self):
        code, report, _ = self.run_stage(StageControl(completed('neutral console output')), ('--require-json',))
        self.assertEqual(code, 1)
        self.assertEqual(report['wrapper_validation_reason'], 'invalid_required_stage_json')
        code, report, _ = self.run_stage(StageControl(completed('neutral console output')))
        self.assertEqual(code, 0)
        self.assertEqual(report['stdout'], 'neutral console output')

    def test_stage_discards_incomplete_required_json(self):
        fragment = '{"certificate_serial":"opaque-fixture"'
        code, report, _ = self.run_stage(StageControl(completed(fragment)), ('--require-json',))
        self.assertEqual(code, 1)
        self.assertEqual(report['stdout'], '')
        self.assertTrue(report['output_discarded_due_to_json_validation'])
        self.assertNotIn('opaque-fixture', json.dumps(report))

    def test_stage_summary_counts_only_actual_arrays(self):
        payload = {'status': 'captured', 'binaries': [1, 2], 'services': 'not-an-array', 'events': []}
        code, report, _ = self.run_stage(StageControl(completed(json.dumps(payload))), ('--summary',))
        self.assertEqual(code, 0)
        self.assertNotIn('stdout', report)
        self.assertEqual(report['binaries_count'], 2)
        self.assertEqual(report['events_count'], 0)
        self.assertNotIn('services_count', report)

    def test_stage_nested_sensitive_field_is_blocked(self):
        code, report, _ = self.run_stage(StageControl(completed(json.dumps({'certificate_serial': 'opaque-fixture'}))))
        self.assertEqual(code, 1)
        self.assertEqual(report['reason'], 'export_privacy_check_failed')
        self.assertFalse((self.directory / 'b2-sample-stage-result.json').exists())

    def test_stage_sanitizes_nested_stdout(self):
        payload = {'private_process_reference': 'fixture-ref', 'boundChildPID': 321, 'child_pid_matched': True, 'note': 'fixture-person X:' + chr(92) + 'private-folder' + chr(92) + 'file.txt'}
        code, report, _ = self.run_stage(StageControl(completed(json.dumps(payload))))
        self.assertEqual(code, 0)
        for token in ('fixture-person', 'fixture-ref', 'boundChildPID', 'private-folder'):
            self.assertNotIn(token, json.dumps(report))
        self.assertTrue(json.loads(report['stdout'])['child_pid_matched'])

    def test_stage_identity_preparation_failure_prevents_execution(self):
        for failure in (completed(exit_code=1), completed(signal=9), completed(status='timeout'), completed(stdout_truncated=True)):
            with self.subTest(status=failure.get('status')):
                control = StageControl(identity=failure)
                code, _, _ = self.run_stage(control, ('--guest-identities',))
                self.assertEqual(code, 124 if failure.get('status') == 'timeout' else 1)
                self.assertEqual(control.calls, ['private-output-token-preparation'])

    def test_stage_identity_preparation_redacts_dynamic_tokens(self):
        control = StageControl(completed(json.dumps({'note': 'dynamic-fixture-box dynamic-fixture-user'})), completed(json.dumps({'a': 'dynamic-fixture-box', 'b': 'fixture-domain' + chr(92) + 'dynamic-fixture-user'})))
        code, report, _ = self.run_stage(control, ('--guest-identities',))
        self.assertEqual(code, 0)
        self.assertEqual(len(control.calls), 2)
        self.assertNotIn('dynamic-fixture-box', json.dumps(report))
        self.assertNotIn('dynamic-fixture-user', json.dumps(report))

    def test_stage_invalid_timeout_or_alias_prevents_execution(self):
        for extra, alias in ((('--timeout', '0'), 'sample-stage'), (('--timeout', '3601'), 'sample-stage'), ((), '../private-stage')):
            control = StageControl()
            code, _, _ = self.run_stage(control, extra, alias)
            self.assertEqual(code, 1)
            self.assertEqual(control.calls, [])

    def test_stage_transport_exception_text_is_withheld(self):
        code, report, _ = self.run_stage(StageControl(OSError('fixture-person confidential message')))
        self.assertEqual(code, 1)
        self.assertNotIn('confidential', json.dumps(report))
        self.assertNotIn('fixture-person', json.dumps(report))

    def test_stage_atomic_failure_cleans_temporary_file(self):
        with patch.object(stage.safety.os, 'replace', side_effect=OSError('fixture-person confidential message')):
            code, report, _ = self.run_stage(StageControl())
        self.assertEqual(code, 1)
        self.assertNotIn('confidential', json.dumps(report))
        self.assertFalse(any(path.suffix == '.tmp' for path in self.directory.iterdir()))

    def assert_cli_dependency_failure(self, helper_source):
        source = self.directory / 'neutral-source.ps1'
        source.write_text('{}')
        helper = self.directory / 'b2-export-safety.py'
        if helper_source is None:
            helper.unlink(missing_ok=True)
        else:
            helper.write_text(helper_source)
        for leaf, arguments in (('b2-pull-evidence.py', ['source.json', 'capture.json']), ('b2-run-stage.py', ['sample-stage', 'neutral-source.ps1'])):
            with self.subTest(cli=leaf):
                script = self.directory / leaf
                script.write_bytes((HERE / leaf).read_bytes())
                result = subprocess.run([sys.executable, str(script), *arguments], cwd=self.directory, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, '')
                self.assertEqual(json.loads(result.stdout), {'status': 'failed', 'reason': 'local_export_safety_unavailable'})
                self.assertNotIn(str(self.directory), result.stdout)
                self.assertNotIn('fixture-person', result.stdout)
                self.assertFalse((self.directory / 'capture.json').exists())
                self.assertFalse((self.directory / 'b2-sample-stage-result.json').exists())

    def test_real_cli_missing_dependency_has_no_traceback(self):
        self.assert_cli_dependency_failure(None)

    def test_real_cli_corrupt_dependency_has_no_traceback(self):
        for source in ('def invalid(:\n', 'raise RuntimeError("fixture-person confidential message")\n', '# Empty helper contract.\n'):
            with self.subTest(damage_kind=source.splitlines()[0].split()[0]):
                self.assert_cli_dependency_failure(source)


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TransferChecks)
    result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
    failed = [test.id().rsplit('.', 1)[-1] for test, _ in result.failures + result.errors]
    print(json.dumps({'result': 'passed' if result.wasSuccessful() else 'failed', 'test_cases': result.testsRun, 'failed_cases': failed, 'guest_calls': 'all_mocked'}))
    raise SystemExit(0 if result.wasSuccessful() else 1)

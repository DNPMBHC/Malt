import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import quote
from xml.etree import ElementTree

from verify import (Redactor, classify_stage_failure, process_environment, reconcile_test_results, run_stage,
                    source_snapshot, summarize_failure_classification, summarize_test_xml, test_results_pass)


class VerificationToolTests(unittest.TestCase):
    @staticmethod
    def sequential_log(states):
        lines = []
        for index, state in enumerate(states):
            name = f'-[DemoTests testScenario{index}]'
            lines.extend([f"Test Case '{name}' started.",
                          f"Test Case '{name}' {state} (0.001 seconds)."])
        skipped, failures = states.count('skipped'), states.count('failed')
        lines.append(f'Executed {len(states)} tests, with {skipped} tests skipped and '
                     f'{failures} failures (0 unexpected) in 0.003 seconds')
        return '\n'.join(lines)

    def test_sequential_log_retains_skip_and_generated_junit_provenance(self):
        text = self.sequential_log(['passed', 'skipped', 'passed'])
        tests, xml, native, evidence = reconcile_test_results(text, None, lambda value: value)
        self.assertEqual(tests, {'total': 3, 'executed': 2, 'passed': 2,
                                 'failures': 0, 'errors': 0, 'skipped': 1})
        self.assertEqual(len(ElementTree.fromstring(xml).findall('testcase/skipped')), 1)
        self.assertEqual(evidence['junitProvenance'], 'generated-from-sequential-xctest-log')
        self.assertFalse(evidence['nativeXMLAvailable'])
        self.assertIsNone(native)
        self.assertTrue(test_results_pass(tests, evidence))

    def test_sequential_log_summary_mismatch_cannot_pass(self):
        text = self.sequential_log(['passed', 'skipped']).replace('Executed 2 tests', 'Executed 3 tests')
        tests, _, _, evidence = reconcile_test_results(text, None, lambda value: value)
        self.assertFalse(evidence['log']['summaryMatchesCases'])
        self.assertFalse(test_results_pass(tests, evidence))

    def test_native_xml_hidden_skip_is_recorded_and_cannot_pass(self):
        text = self.sequential_log(['passed', 'skipped'])
        xml = b'<testsuite><testcase name="first"/><testcase name="second"/></testsuite>'
        tests, generated, native, evidence = reconcile_test_results(text, xml, lambda value: value)
        self.assertEqual(tests['skipped'], 1)
        self.assertEqual(evidence['nativeXMLCounts']['skipped'], 0)
        self.assertTrue(evidence['nativeXMLMismatch'])
        self.assertIsNotNone(native)
        self.assertEqual(len(ElementTree.fromstring(generated).findall('testcase/skipped')), 1)
        self.assertFalse(test_results_pass(tests, evidence))

    def test_native_xml_without_real_xctest_log_cannot_prove_execution(self):
        xml = b'<testsuite><testcase name="first"/></testsuite>'
        tests, _, _, evidence = reconcile_test_results('', xml, lambda value: value)
        self.assertIsNone(tests)
        self.assertFalse(evidence['countsVerified'])
        self.assertFalse(test_results_pass(tests, evidence))

    def test_stage_creates_missing_output_directory_and_redacts_log(self):
        with tempfile.TemporaryDirectory(prefix='task-07-test-') as directory:
            workspace = pathlib.Path(directory).resolve()
            repo = workspace / 'project-a'
            repo.mkdir()
            output = workspace / 'evidence' / 'nested'
            redactor = Redactor(workspace, repo, repo / 'module-x', workspace / 'build-cache')
            self.assertFalse(output.exists())
            with patch('verify.print') as status:
                result = run_stage('synthetic', [sys.executable, '-c', 'import os; print(os.getcwd())'],
                                   repo, os.environ.copy(), output, redactor, 10)
            self.assertEqual(result['exitCode'], 0)
            self.assertEqual(result['state'], 'passed')
            text = (output / 'synthetic.log').read_text()
            self.assertEqual(text, '<workspace>/my-project\n')
            self.assertNotIn(directory, text)
            self.assertTrue(all(directory not in str(call) for call in status.call_args_list))

    def test_git_configuration_is_appended_and_parent_environment_unchanged(self):
        original = {'PATH': '/usr/bin', 'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'credential.interactive', 'GIT_CONFIG_VALUE_0': 'never'}
        with patch.dict(os.environ, original, clear=True):
            result = process_environment()
            self.assertEqual(result['GIT_CONFIG_COUNT'], '3')
            self.assertEqual(result['GIT_CONFIG_KEY_0'], 'credential.interactive')
            self.assertEqual(result['GIT_CONFIG_VALUE_1'], 'git@github.com:')
            self.assertEqual(result['GIT_CONFIG_VALUE_2'], 'ssh://git@github.com/')
            self.assertEqual(dict(os.environ), original)

    def test_http_version_override_is_process_scoped_and_appended(self):
        original = {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'credential.interactive',
                    'GIT_CONFIG_VALUE_0': 'never'}
        with patch.dict(os.environ, original, clear=True):
            result = process_environment('HTTP/1.1')
            self.assertEqual(result['GIT_CONFIG_COUNT'], '4')
            self.assertEqual(result['GIT_CONFIG_KEY_3'], 'http.version')
            self.assertEqual(result['GIT_CONFIG_VALUE_3'], 'HTTP/1.1')
            self.assertEqual(result['GIT_CONFIG_KEY_0'], original['GIT_CONFIG_KEY_0'])
            self.assertEqual(dict(os.environ), original)

    def test_paths_identifiers_remote_and_email_are_redacted(self):
        root = pathlib.Path('/workspace/demo-app')
        repo = root / 'project-a'
        package = repo / 'PrivateModule'
        redactor = Redactor(root, repo, package, pathlib.Path('/tmp/task-07-demo'))
        value = str(package / 'Sources/PrivateModule/File.swift') + ' privatemodule PROJECT-A https://example.invalid/repository git@example.invalid:repository example@example.invalid /tmp/task-07-demo/object'
        result = redactor(value)
        for secret in [str(root), 'PrivateModule', 'privatemodule', 'PROJECT-A', 'example.invalid', '/tmp/task-07-demo']:
            self.assertNotIn(secret, result)
        self.assertIn('ModuleX', result)
        self.assertIn('<dependency-remote>', result)

    def test_identity_and_secret_environment_values_are_redacted(self):
        with patch('pathlib.Path.home', return_value=pathlib.Path('/home/demo-user')):
            with patch.dict(os.environ, {'USER': 'demo-user', 'LOGNAME': 'demo-user'}, clear=True):
                redactor = Redactor(pathlib.Path('/workspace/demo-app'),
                                    pathlib.Path('/workspace/demo-app/project-a'),
                                    pathlib.Path('/workspace/demo-app/project-a/module-x'),
                                    pathlib.Path('/tmp/task-07-demo'))
        value = (
            'export USER=demo-user\nexport LOGNAME="demo-user"\n'
            'GIT_AUTHOR_NAME="Demo Contributor"\n'
            'GIT_COMMITTER_NAME=Demo Contributor\n'
            'export API_TOKEN=synthetic-token\n'
            '"CLIENT_SECRET": "synthetic-secret", PASSWORD=synthetic-password\n'
            'Authorization: Bearer synthetic-bearer\n'
            'warning: demo-user requested a build; @DNPMBHC is allowed\n'
        )
        result = redactor(value)
        for secret in ['demo-user', 'Demo Contributor', 'synthetic-token', 'synthetic-secret',
                       'synthetic-password', 'synthetic-bearer']:
            self.assertNotIn(secret, result)
        self.assertIn('<identity>', result)
        self.assertIn('<secret>', result)
        self.assertIn('@DNPMBHC', result)

    def test_encoded_and_shell_escaped_paths_are_redacted(self):
        root = pathlib.Path('/workspace/demo folder')
        repo = root / 'project-a'
        package = repo / 'module-x'
        redactor = Redactor(root, repo, package, pathlib.Path('/tmp/task-07-demo'))
        source = str(package / 'Sources/File.swift')
        for value in [quote(source, safe='/'), 'file://' + quote(source, safe='/'),
                      source.replace(' ', '\\ ')]:
            with self.subTest(form=value):
                result = redactor(value)
                self.assertNotIn('demo folder', result)
                self.assertNotIn('demo%20folder', result)
                self.assertNotIn('demo\\ folder', result)
                self.assertIn('<workspace>/my-project/ModuleX', result)

    def test_exported_environment_and_system_paths_are_not_evidence(self):
        root = pathlib.Path('/workspace/demo-app')
        redactor = Redactor(root, root / 'project-a', root / 'project-a/module-x',
                            pathlib.Path('/tmp/task-07-demo'))
        value = ('    export CUSTOM_BUILD_LABEL=synthetic-private-value\n'
                 '    export CUSTOM_PATH\\=/Applications/demo-app/bin\n'
                 'tool /Applications/demo-app/bin /Library/demo-cache/file\n')
        result = redactor(value)
        for secret in ['synthetic-private-value', 'CUSTOM_PATH', '/Applications/', '/Library/']:
            self.assertNotIn(secret, result)
        self.assertEqual(result.count('<environment redacted>'), 2)

    def test_xml_is_redacted_structurally_and_retains_test_counts(self):
        root = pathlib.Path('/workspace/demo-app')
        repo = root / 'project-a'
        package = repo / 'module-x'
        redactor = Redactor(root, repo, package, pathlib.Path('/tmp/task-07-demo'))
        xml = (
            '<testsuite xmlns="urn:demo-xunit">'
            '<testcase name="success"/>'
            '<testcase name="failure"><failure '
            'message="/workspace/demo-app/project-a/Source.swift:4">'
            'API_TOKEN=synthetic-token</failure>/tmp/task-07-demo/object</testcase>'
            '<testcase name="error"><error>https://example.invalid/private</error></testcase>'
            '<testcase name="skip"><skipped/></testcase>'
            '</testsuite>'
        )
        counts, safe_xml = summarize_test_xml(xml.encode(), redactor)
        safe_root = ElementTree.fromstring(safe_xml)
        failure = safe_root.find('.//{urn:demo-xunit}failure')
        self.assertEqual(counts, {'total': 4, 'failures': 1, 'errors': 1, 'skipped': 1})
        self.assertEqual(failure.attrib['message'], '<workspace>/my-project/Source.swift:4')
        self.assertEqual(failure.text, 'API_TOKEN=<secret>')
        self.assertEqual(failure.tail, '<build-cache>/object')
        self.assertIn('&lt;workspace&gt;', safe_xml)
        for secret in ['/workspace/demo-app', '/tmp/task-07-demo', 'synthetic-token', 'example.invalid']:
            self.assertNotIn(secret, safe_xml)

    def test_missing_empty_and_all_skipped_test_results_do_not_pass(self):
        self.assertFalse(test_results_pass(None))
        self.assertFalse(test_results_pass({'total': 0, 'failures': 0, 'errors': 0, 'skipped': 0}))
        self.assertFalse(test_results_pass({'total': 5, 'failures': 0, 'errors': 0, 'skipped': 5}))
        self.assertTrue(test_results_pass({'total': 2, 'failures': 0, 'errors': 0, 'skipped': 1}))
        self.assertFalse(test_results_pass({'total': 2, 'failures': 1, 'errors': 0, 'skipped': 0}))
        self.assertFalse(test_results_pass({'total': 2, 'failures': 0, 'errors': 1, 'skipped': 0}))

    def test_snapshot_detects_changes_to_resources_settings_and_ignored_inputs(self):
        with tempfile.TemporaryDirectory(prefix='task-07-test-') as directory:
            workspace = pathlib.Path(directory)
            repo = workspace / 'project-a'
            package = repo / 'module-x'
            inputs = [
                'module-x/Package.swift',
                'project-a.xcodeproj/project.pbxproj',
                'project-a.xcodeproj/xcshareddata/xcschemes/project-a.xcscheme',
                'App/Localizable.xcstrings', 'App/app.entitlements', 'App/Info.plist',
                'App/Assets.xcassets/Contents.json', 'App/Assets.xcassets/demo.imageset/demo.png',
                'Config/debug.xcconfig', 'Config/ignored-input.data',
            ]
            for name in inputs:
                file = repo / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'demo input')
            (repo / '.gitignore').write_text('Config/ignored-input.data\n')
            redactor = Redactor(workspace, repo, package, workspace / 'build-cache')
            initial = source_snapshot(repo, redactor)
            for name in inputs:
                key = redactor(name)
                self.assertIn(key, initial)
                (repo / name).write_bytes(b'changed input')
                changed = source_snapshot(repo, redactor)
                self.assertNotEqual(initial[key], changed[key])
            added = repo / 'App/new-resource.data'
            added.write_bytes(b'new input')
            self.assertIn(redactor(str(added.relative_to(repo))), source_snapshot(repo, redactor))
            added.unlink()
            self.assertNotIn(redactor(str(added.relative_to(repo))), source_snapshot(repo, redactor))

    def test_snapshot_excludes_build_and_user_state(self):
        with tempfile.TemporaryDirectory(prefix='task-07-test-') as directory:
            workspace = pathlib.Path(directory)
            repo = workspace / 'project-a'
            package = repo / 'module-x'
            package.mkdir(parents=True)
            (package / 'Package.swift').write_text('// synthetic package input\n')
            redactor = Redactor(workspace, repo, package, workspace / 'build-cache')
            initial = source_snapshot(repo, redactor)
            for name in ['.git/config', '.build/cache.swift', 'DerivedData/generated.swift',
                         'project-a.xcodeproj/xcuserdata/demo.xcuserstate',
                         '__pycache__/cache.pyc', '.DS_Store']:
                file = repo / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'generated state')
            self.assertEqual(initial, source_snapshot(repo, redactor))

    def test_snapshot_retains_inputs_with_colliding_anonymized_asset_names(self):
        with tempfile.TemporaryDirectory(prefix='task-07-test-') as directory:
            workspace = pathlib.Path(directory)
            repo = workspace / 'project-a'
            repo.mkdir()
            redactor = Redactor(workspace, repo, repo / 'module-x', workspace / 'build-cache')
            first, second = repo / 'asset@2x.png', repo / 'asset@3x.png'
            first.write_bytes(b'first asset')
            second.write_bytes(b'second asset')
            before = source_snapshot(repo, redactor)
            self.assertEqual(len(before), 2)
            self.assertTrue(all('#input-' in key for key in before))
            first.rename(repo / 'asset@4x.png')
            self.assertNotEqual(before, source_snapshot(repo, redactor))

    def test_failure_classification_separates_network_fetch_from_code_errors(self):
        self.assertIsNone(classify_stage_failure('xcode-build', 0, 'BUILD SUCCEEDED'))
        self.assertEqual(
            classify_stage_failure('xcode-resolve', 74, 'curl error 28: Operation timed out'),
            'network_or_dependency_fetch',
        )
        self.assertEqual(
            classify_stage_failure('swift-resolve', 124, 'time limit exceeded'),
            'network_or_dependency_fetch',
        )
        self.assertEqual(
            classify_stage_failure('xcode-build', 65, 'error: cannot find type Foo in scope'),
            'code_or_build_failure',
        )
        summary = summarize_failure_classification({
            'swift-resolve': {'exitCode': 0},
            'xcode-resolve': {'exitCode': 74, 'failureCategory': 'network_or_dependency_fetch'},
            'xcode-build': {'exitCode': None, 'state': 'skipped'},
        })
        self.assertEqual(summary['overall'], 'network_or_dependency_fetch')
        self.assertTrue(summary['networkOrFetchBlocked'])
        self.assertFalse(summary['codeOrBuildBlocked'])


if __name__ == '__main__':
    unittest.main()

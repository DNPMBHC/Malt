import os
import re
import shutil
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_launch_gate as gate
from package_launch_gate import observe_launch, verify_updater_removed, isolated_launch_environment


class PackageLaunchGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="demo-app-launch-test-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def executable(self, body, interpreter="/usr/bin/env python3"):
        path = self.root / "demo-app"
        path.write_text("#!" + interpreter + "\n" + body)
        path.chmod(0o755)
        return path

    def test_normal_process_survives_default_four_seconds_and_is_reaped(self):
        process = self.executable(
            "import os,time\nprint(os.getpid(),flush=True)\ntime.sleep(30)\n"
        )
        result = observe_launch(process, self.root / "launch.log")
        self.assertTrue(result["passed"])
        self.assertEqual(result["requiredSurvivalSeconds"], 4)
        self.assertGreaterEqual(result["observedSeconds"], 4)
        pid = int((self.root / "launch.log").read_text().strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_exit_after_original_short_window_fails(self):
        process = self.executable("import time\ntime.sleep(2.6)\nraise SystemExit(1)\n")
        result = observe_launch(process, self.root / "launch.log")
        self.assertFalse(result["passed"])
        self.assertFalse(result["survived"])
        self.assertEqual(result["exitCodeDuringObservation"], 1)

    def test_even_clean_early_exit_fails(self):
        process = self.executable("raise SystemExit(0)\n")
        result = observe_launch(process, self.root / "launch.log")
        self.assertFalse(result["passed"])
        self.assertEqual(result["exitCodeDuringObservation"], 0)

    def test_late_dyld_message_fails_even_while_process_survives(self):
        process = self.executable(
            "/bin/sleep 0.15\n"
            "echo 'dyld: Library not loaded: @rpath/Sparkle.framework/Sparkle'\n"
            "exec /bin/sleep 30\n",
            interpreter="/bin/sh",
        )
        result = observe_launch(process, self.root / "launch.log", seconds=1.5)
        self.assertTrue(result["survived"])
        self.assertFalse(result["passed"])
        self.assertGreater(result["dyldErrorCount"], 0)

    def test_signature_error_without_dyld_prefix_fails(self):
        process = self.executable(
            "echo 'code signature not valid: different Team IDs'\n"
            "exec /bin/sleep 30\n",
            interpreter="/bin/sh",
        )
        result = observe_launch(process, self.root / "launch.log", seconds=1.5)
        self.assertFalse(result["passed"])
        self.assertGreater(result["dyldErrorCount"], 0)

    def test_isolated_process_does_not_inherit_runtime_configuration(self):
        executable = self.root / "isolated-process"
        executable.write_text(
            '#!/bin/sh\n'
            '[ -z "$FEATURE_RUNTIME_ROOT" ] || exit 21\n'
            '[ "$PATH" = "/usr/bin:/bin:/usr/sbin:/sbin" ] || exit 22\n'
            '[ -d "$CFFIXED_USER_HOME" ] || exit 23\n'
            'echo clean-user-data\n'
            'exec /bin/sleep 30\n'
        )
        executable.chmod(0o755)
        with patch.dict(os.environ, {"FEATURE_RUNTIME_ROOT": "/missing/developer-runtime"}):
            result = observe_launch(
                executable, self.root / "isolated.log", seconds=1.0,
                environment=isolated_launch_environment(self.root),
            )
        self.assertTrue(result["passed"])
        self.assertEqual((self.root / "isolated.log").read_text().strip(), "clean-user-data")

    def test_smoke_environment_always_bypasses_the_real_application(self):
        env = isolated_launch_environment(self.root)
        self.assertEqual(env[gate.SMOKE_ENV_KEY], '1')
        self.assertEqual(env['HOME'], str(self.root))
        self.assertEqual(env['TMPDIR'], str(self.root))
        self.assertNotIn('FEATURE_RUNTIME_ROOT', env)

    def test_binary_without_safe_entrypoint_is_not_launched(self):
        app = self.root / 'demo-app.app'
        executable = app / 'Contents/MacOS/demo-app'
        executable.parent.mkdir(parents=True)
        executable.write_text('synthetic legacy executable')
        with patch.object(gate, 'verify_updater_removed', return_value={'passed': True}), \
             patch.object(gate, 'observe_launch') as launch, \
             patch('builtins.print'), \
             patch.object(sys, 'argv', ['package_launch_gate', '--app', str(app),
                                       '--executable-name', 'demo-app',
                                       '--output', str(self.root / 'report.json')]):
            with self.assertRaises(SystemExit):
                gate.main()
        launch.assert_not_called()

    def test_survival_without_foundation_handshake_fails(self):
        executable = self.executable('exec /bin/sleep 30\n', interpreter='/bin/sh')
        result = observe_launch(executable, self.root / 'handshake.log', seconds=0.3,
                                required_marker=gate.SMOKE_MARKER)
        self.assertTrue(result['survived'])
        self.assertFalse(result['requiredMarkerObserved'])
        self.assertFalse(result['passed'])

    @patch("package_launch_gate.subprocess.run")
    def test_stale_dynamic_updater_dependency_is_rejected(self, run):
        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout="demo-app:\n  @rpath/Sparkle.framework/Versions/B/Sparkle\n"
        )
        result = verify_updater_removed(self.root, self.root / "demo-app")
        self.assertTrue(result["sparkleLinked"])
        self.assertFalse(result["passed"])

    @patch("package_launch_gate.subprocess.run")
    def test_stale_embedded_updater_framework_is_rejected(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, stdout="demo-app:\n")
        (self.root / "Contents" / "Frameworks" / "Sparkle.framework").mkdir(parents=True)
        result = verify_updater_removed(self.root, self.root / "demo-app")
        self.assertTrue(result["sparkleBundled"])
        self.assertFalse(result["passed"])

    @patch("package_launch_gate.subprocess.run")
    def test_system_only_dependencies_pass(self, run):
        run.return_value = subprocess.CompletedProcess(
            [], 0, stdout="demo-app:\n /usr/lib/libSystem.B.dylib\n"
        )
        result = verify_updater_removed(self.root, self.root / "demo-app")
        self.assertTrue(result["passed"])


class FoundationSmokeEntryPointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('swiftc')
        if sys.platform != 'darwin' or not compiler:
            raise unittest.SkipTest('independent Foundation harness requires macOS Swift')
        cls.temporary = tempfile.TemporaryDirectory(prefix='foundation-entry-test-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        candidates = [path for path in Path(__file__).resolve().parents[1].glob('*/Views/*App.swift')
                      if 'enum ApplicationEntryPoint {' in path.read_text()]
        if len(candidates) != 1:
            raise AssertionError('Expected one same-file application entry point')
        source = candidates[0].read_text()
        start = source.index('@main\n@MainActor\nenum ApplicationEntryPoint {')
        application = re.search(r'^struct (\w+): App \{', source[start:], re.MULTILINE)
        if application is None:
            raise AssertionError('Expected the normal SwiftUI application after its entry point')
        entry = source[start:start + application.start()]
        entry = entry.replace(application.group(1) + '.main()', 'SyntheticApplication.main()')
        stub = ('\nenum SyntheticApplication {\n'
                '    @MainActor static func main() { print("synthetic-application-entered") }\n'
                '}\n')
        harness = cls.root / 'entry.swift'
        harness.write_text('import Foundation\n' + entry + stub)
        cls.executable = cls.root / 'foundation-entry'
        result = subprocess.run([compiler, '-swift-version', '6', '-parse-as-library',
                                 '-module-cache-path', str(cls.root / 'module-cache'),
                                 str(harness), '-o', str(cls.executable)],
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError('Independent Foundation entry point did not compile')

    def test_compiled_smoke_branch_survives_without_entering_application(self):
        self.assertTrue(gate.verify_smoke_entrypoint(self.executable)['passed'])
        log = self.root / 'foundation-only.log'
        result = observe_launch(self.executable, log, seconds=4,
                                environment=isolated_launch_environment(self.root),
                                required_marker=gate.SMOKE_MARKER)
        self.assertTrue(result['passed'])
        self.assertGreaterEqual(result['observedSeconds'], 4)
        self.assertNotIn('synthetic-application-entered', log.read_text())

    def test_compiled_normal_branch_forwards_only_to_synthetic_application(self):
        env = isolated_launch_environment(self.root)
        del env[gate.SMOKE_ENV_KEY]
        result = subprocess.run([str(self.executable)], env=env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'synthetic-application-entered')
        self.assertNotIn(gate.SMOKE_MARKER, result.stdout)


if __name__ == "__main__":
    unittest.main()

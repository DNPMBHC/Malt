import pathlib
import subprocess
import unittest


TASK_DIR = pathlib.Path(__file__).resolve().parent
SCRIPT = TASK_DIR / 'dev_restart.sh'


class DevRestartScriptTests(unittest.TestCase):
    def test_script_syntax_and_no_hardcoded_user_paths(self):
        self.assertTrue(SCRIPT.is_file())
        text = SCRIPT.read_text(encoding='utf-8')
        self.assertNotIn('/Users/', text)
        self.assertNotIn('git config --global', text)
        syntax = subprocess.run(['bash', '-n', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_help_and_invalid_option(self):
        help_res = subprocess.run([str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(help_res.returncode, 0)
        self.assertIn('--dry-run', help_res.stdout)
        self.assertIn('--no-build', help_res.stdout)

        bad_res = subprocess.run([str(SCRIPT), '--unknown-flag-xyz'], capture_output=True, text=True)
        self.assertEqual(bad_res.returncode, 2)
        self.assertIn('unknown option', bad_res.stderr)


if __name__ == '__main__':
    unittest.main()

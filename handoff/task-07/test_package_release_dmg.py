import pathlib
import subprocess
import unittest


TASK_DIR = pathlib.Path(__file__).resolve().parent
SCRIPT = TASK_DIR / 'package_release_dmg.sh'
WORKSPACE = TASK_DIR.parents[1]


class PackageReleaseDmgTests(unittest.TestCase):
    def test_script_syntax_and_help(self):
        syntax = subprocess.run(['bash', '-n', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        help_run = subprocess.run([str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(help_run.returncode, 0, help_run.stderr)
        self.assertIn('Hardened Runtime', help_run.stdout)

    def test_rejects_output_dir_inside_workspace(self):
        bad_dir = WORKSPACE / 'handoff/task-07/tmp-bad-dmg'
        run = subprocess.run(
            [str(SCRIPT), '--dry-run', '--output-dir', str(bad_dir)],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('outside the workspace', run.stderr)

    def test_dry_run_resolves_release_hardened_runtime(self):
        run = subprocess.run(
            [str(SCRIPT), '--dry-run', '--configuration', 'Release'],
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('configuration=Release', run.stdout)
        self.assertIn('hardened_runtime=YES', run.stdout)
        self.assertIn('ENABLE_HARDENED_RUNTIME=YES', run.stdout)


if __name__ == '__main__':
    unittest.main()

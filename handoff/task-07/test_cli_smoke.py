import pathlib
import tempfile
import unittest

from cli_smoke import evaluate_check
from run_cli_checks import localized_variants, matches_any_localized


class CLISmokeDiagnosticTests(unittest.TestCase):
    def test_missing_positionals_cannot_prove_unknown_option_rejection(self):
        result = evaluate_check({'exitCode': 64}, "Error: Missing expected argument '<bottle>'",
                                64, ["Unknown option '--demo-invalid'"], ['Missing expected argument'])
        self.assertFalse(result['passed'])

    def test_expected_exit_without_specific_diagnostic_cannot_pass(self):
        result = evaluate_check({'exitCode': 64}, 'Error: unrelated parser failure',
                                64, ["The option '--demo-flag' does not take any value"])
        self.assertFalse(result['passed'])

    def test_specific_unknown_option_diagnostic_passes(self):
        result = evaluate_check({'exitCode': 64}, "Error: Unknown option '--demo-invalid'",
                                64, ["Unknown option '--demo-invalid'"], ['Missing expected argument'])
        self.assertTrue(result['passed'])

    def test_matching_diagnostic_with_wrong_exit_cannot_pass(self):
        result = evaluate_check({'exitCode': 0}, "Error: Unknown option '--demo-invalid'",
                                64, ["Unknown option '--demo-invalid'"])
        self.assertFalse(result['passed'])

    def test_localized_variants_format_exit_and_signal_templates(self):
        with tempfile.TemporaryDirectory(prefix='task-07-l10n-') as directory:
            repo = pathlib.Path(directory)
            app = repo / 'App'
            app.mkdir()
            (app / 'Localizable.xcstrings').write_text(
                '{"strings":{"runtime.issue.processExit":{"localizations":'
                '{"zh-Hans":{"stringUnit":{"value":"程序已退出，退出码为 %d。"}}}}}}',
                encoding='utf-8',
            )
            variants = localized_variants(repo, 'runtime.issue.processExit', 'The program exited with code %d.', 42)
            self.assertIn('The program exited with code 42.', variants)
            self.assertIn('程序已退出，退出码为 42。', variants)
            self.assertTrue(matches_any_localized('程序已退出，退出码为 42。\n', variants))
            self.assertFalse(matches_any_localized('程序已退出，退出码为 7。\n', variants))


if __name__ == '__main__':
    unittest.main()

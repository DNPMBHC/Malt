# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline contracts for runtime options consumed by the bundled helper patches."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent


def patch_text(prefix):
    matches = list(ROOT.glob(f"*/utm-custom/patches/{prefix}*.patch"))
    if len(matches) != 1:
        raise AssertionError("Expected exactly one helper patch for " + prefix)
    return matches[0].read_text()


def added_source(prefix):
    return "\n".join(
        line[1:] for line in patch_text(prefix).splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


class RuntimeOptionContracts(unittest.TestCase):
    def test_mouse_coalescing_has_existing_1500_microsecond_default_and_zero_disables(self):
        source = added_source("06")
        self.assertIn('environment["UTM_MOUSE_COALESCE_US"]', source)
        self.assertIn("let defaultUs = 1500", source)
        self.assertRegex(source, r"if parsed <= 0 \{\s*return 0")
        self.assertRegex(source, r"if mouseCoalesceWindowNs == 0 \{[\s\S]*?inputDelegate\?\.mouseMove")

    def test_both_key_guard_layers_only_enable_for_explicit_one_or_absent_value(self):
        source = added_source("07")
        overrides = re.findall(
            r'environment\["UTM_GAME_SHELL_KEY_GUARD"\]\s*'
            r'\.map \{ \$0 == "1" \} \?\? true\)', source
        )
        self.assertEqual(len(overrides), 2)
        self.assertEqual(source.count('arguments.contains("--app-shell-vm")'), 2)
        self.assertEqual(source.count('environment["UTM_APP_SHELL_VM"]'), 2)
        self.assertEqual(source.count('arguments.contains("--game-shell-vm")'), 2)
        self.assertEqual(source.count('environment["UTM_GAME_SHELL_VM"]'), 2)

    def test_key_guard_layers_require_fullscreen_shell_context_even_when_enabled(self):
        source = added_source("07")
        self.assertRegex(
            source,
            r'let guardEnabled = isGameShell && isFullScreen\s*&& '
            r'\(ProcessInfo\.processInfo\.environment\["UTM_GAME_SHELL_KEY_GUARD"\]'
        )
        self.assertRegex(
            source,
            r'private var shouldGuardGameShellShortcuts: Bool \{\s*'
            r'isGameShellFullScreenActive\s*&& '
            r'\(ProcessInfo\.processInfo\.environment\["UTM_GAME_SHELL_KEY_GUARD"\]'
        )

    def test_app_shell_monitor_uses_the_same_explicit_value_and_fullscreen_contract(self):
        source = added_source("08")
        monitor = source.split("func installAppShellKeyGuardIfNeeded()", 1)[1]
        self.assertRegex(
            monitor,
            r'let guardEnabled = ProcessInfo\.processInfo\.environment\["UTM_GAME_SHELL_KEY_GUARD"\]\s*'
            r'\.map \{ \$0 == "1" \} \?\? true'
        )
        self.assertRegex(
            monitor,
            r'guard guardEnabled, self\?\.window\?\.styleMask\.contains\(\.fullScreen\) == true '
            r'else \{\s*return event'
        )
        self.assertIn('{ [weak self] event in', monitor)

    def test_shortcut_filters_keep_escape_combinations_and_only_block_expected_keys(self):
        for prefix, expected_count in (("07", 2), ("08", 1)):
            source = added_source(prefix)
            self.assertEqual(source.count("!flags.contains(.option)"), expected_count)
            self.assertEqual(source.count("!flags.contains(.control)"), expected_count)
            guarded_cases = re.findall(r"case (kVK_ANSI_W[^:]+):", source)
            self.assertEqual(len(guarded_cases), expected_count)
            for keys in guarded_cases:
                self.assertEqual(
                    [key.strip() for key in keys.split(",")],
                    ["kVK_ANSI_W", "kVK_ANSI_Q", "kVK_ANSI_H", "kVK_ANSI_M"]
                )

    def test_left_command_guard_still_accepts_explicit_off(self):
        source = added_source("07")
        block = source.split("private var shouldBlockLeftWinKey: Bool", 1)[1]
        block = block.split("override func performKeyEquivalent", 1)[0]
        self.assertIn('if let env = ProcessInfo.processInfo.environment["UTM_BLOCK_WIN_KEY"]', block)
        self.assertIn('return env == "1"', block)
        self.assertIn("return isGameShellFullScreenActive", block)

    def test_cache_disable_is_consumed_without_creating_or_exposing_a_cache_path(self):
        source = added_source("05-render-thread-qos-and-dxmt-cache")
        self.assertIn('environment[@"UTM_DXMT_SHADER_CACHE_ENABLED"]', source)
        disabled = source.split('if ([cacheEnabled isEqualToString:@"0"]) {', 1)[1]
        disabled = disabled.split("} else {", 1)[0]
        self.assertIn('self.mutableEnvironment[@"DXMT_SHADER_CACHE"] = @"0";', disabled)
        self.assertIn('removeObjectForKey:@"DXMT_SHADER_CACHE_PATH"', disabled)
        self.assertNotIn("createDirectoryAtURL", disabled)
        self.assertIn('self.mutableEnvironment[@"DXMT_SHADER_CACHE"] = @"1";', source)

    def test_helper_metadata_declares_the_runtime_settings_contract(self):
        source = added_source("07")
        self.assertRegex(
            source,
            r'<key>UTMRuntimeSettingsContractVersion</key>\s*<integer>1</integer>'
        )

    def test_prepare_only_registers_lifecycle_and_returns_before_vm_start(self):
        source = added_source("08")
        launch = source.split("private func launchAppShellVM", 1)[1]
        launch = launch.split("private extension AppDelegate", 1)[0]
        prepare = re.search(
            r'if CommandLine\.arguments\.contains\("--app-shell-prepare-only"\) \{\s*return\s*\}',
            launch
        )
        self.assertIsNotNone(prepare)
        self.assertLess(launch.index("guard let resolvedVM = vm"), prepare.start())
        self.assertLess(launch.index("self.stopObserver = resolvedVM.$state"), prepare.start())
        self.assertLess(launch.index("self.hasStarted = false"), prepare.start())
        self.assertLess(prepare.end(), launch.index("data.run(vm: resolvedVM)"))
        self.assertIn("else if self.hasStarted && state == .stopped", launch)
        self.assertIn("NSApp.terminate(nil)", launch)

    def test_configuration_reload_rejects_live_or_saved_state_and_invalid_manifest(self):
        source = patch_text("08").split(
            "diff --git a/Scripting/UTMScriptingVirtualMachineImpl.swift", 1
        )[1]
        self.assertIn("+            guard vm.state == .stopped,", source)
        self.assertIn("+                  !vm.registryEntry.isSuspended,", source)
        self.assertIn(
            "+                  try UTMSnapshotManifest.load(from: vm.pathUrl)?.suspendIdentifier == nil else {",
            source
        )
        self.assertIn("throw ScriptingError.notStopped", source)
        self.assertNotIn("try?", source)

    def test_modified_patch_hunk_counts_remain_valid(self):
        for prefix in ("05-render-thread-qos-and-dxmt-cache", "07", "08"):
            lines = patch_text(prefix).splitlines()
            for index, line in enumerate(lines):
                match = re.match(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@", line)
                if not match:
                    continue
                body = []
                for following in lines[index + 1:]:
                    if following.startswith(("@@ ", "diff --git ")):
                        break
                    body.append(following)
                with self.subTest(patch=prefix, hunk=index):
                    self.assertEqual(sum(part.startswith((" ", "-")) for part in body), int(match[2]))
                    self.assertEqual(sum(part.startswith((" ", "+")) for part in body), int(match[4]))


if __name__ == "__main__":
    unittest.main()

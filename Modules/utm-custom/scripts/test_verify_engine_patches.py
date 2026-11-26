#!/usr/bin/env python3
"""Isolated patch-stack validation tests. Owner: @DNPMBHC."""
from __future__ import annotations

import difflib
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import verify_engine_patches as verifier


UTM_TARGET = "Configuration/UTMQemuConfiguration+Arguments.swift"
DISPLAY_TARGET = "Sources/CocoaSpice/CSDisplay.m"


def patch_text(target: str, before: str, after: str, *, source: str | None = None) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile="a/" + (source or target), tofile="b/" + target,
    ))


class ExactPatchScopeTests(unittest.TestCase):
    def test_accepts_the_specific_scripting_target(self) -> None:
        target = "Scripting/UTMScriptingVirtualMachineImpl.swift"
        report = verifier.audit_patch_text("01.patch", patch_text(target, "old\n", "new\n"))
        self.assertEqual(report["targets"], [target])

    def test_rejects_unrelated_and_allowed_prefix_lookalikes(self) -> None:
        for target in (
            "Other/untrusted.swift",
            UTM_TARGET + ".untrusted",
            UTM_TARGET + "/../../untrusted.swift",
            "../" + UTM_TARGET,
        ):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "disallowed target"):
                verifier.audit_patch_text("01.patch", patch_text(target, "old\n", "new\n"))

    def test_rejects_rename_from_an_out_of_scope_source(self) -> None:
        text = patch_text(UTM_TARGET, "old\n", "new\n", source="Other/untrusted.swift")
        with self.assertRaisesRegex(ValueError, "disallowed target"):
            verifier.audit_patch_text("01.patch", text)

    def test_rejects_empty_patch(self) -> None:
        with self.assertRaisesRegex(ValueError, "no modified target"):
            verifier.audit_patch_text("01.patch", "")


class IsolatedOrderedStackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="engine-patch-tests-")
        self.root = Path(self.temporary.name)
        self.patches = self.root / "patches"
        self.patches.mkdir()
        self.repo = self.create_repo("engine", UTM_TARGET)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, repo: Path, *arguments: str) -> bytes:
        return subprocess.check_output(
            ["git", "-C", str(repo), *arguments], stderr=subprocess.PIPE,
        )

    def create_repo(self, name: str, target: str) -> Path:
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "--quiet")
        source = repo / target
        source.parent.mkdir(parents=True)
        source.write_text("base\n", encoding="utf-8")
        self.git(repo, "add", "--", target)
        self.git(
            repo, "-c", "user.name=@DNPMBHC", "-c",
            "user.email=DNPMBHC@users.noreply.github.com", "commit", "--quiet", "-m", "Test fixture",
        )
        return repo

    def write_patch(self, name: str, target: str, before: str, after: str) -> None:
        (self.patches / name).write_text(patch_text(target, before, after), encoding="utf-8")

    def checkout_snapshot(self, repo: Path, target: str) -> dict[str, bytes | str]:
        return {
            "status": self.git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
            "head": self.git(repo, "rev-parse", "HEAD"),
            "index": hashlib.sha256((repo / ".git/index").read_bytes()).hexdigest(),
            "file": (repo / target).read_bytes(),
        }

    def dirty_checkout(self) -> None:
        source = self.repo / UTM_TARGET
        source.write_text("preexisting staged change\n", encoding="utf-8")
        self.git(self.repo, "add", "--", UTM_TARGET)
        source.write_text("preexisting working change\n", encoding="utf-8")
        (self.repo / "untracked.txt").write_text("keep\n", encoding="utf-8")

    def test_dependent_stack_checks_against_head_and_preserves_dirty_checkout(self) -> None:
        self.write_patch("01.patch", UTM_TARGET, "base\n", "middle\n")
        self.write_patch("02.patch", UTM_TARGET, "middle\n", "final\n")
        self.dirty_checkout()
        before = self.checkout_snapshot(self.repo, UTM_TARGET)
        report = verifier.verify_patches_directory(self.patches, utm_repo=self.repo)
        self.assertEqual(report["git_apply_checks"]["utm_ordered_apply_checks"], 2)
        self.assertTrue(report["git_apply_checks"]["utm_stacked_apply_check"])
        self.assertEqual(self.checkout_snapshot(self.repo, UTM_TARGET), before)

    def test_invalid_later_patch_preserves_dirty_checkout(self) -> None:
        self.write_patch("01.patch", UTM_TARGET, "base\n", "middle\n")
        self.write_patch("02.patch", UTM_TARGET, "not-the-previous-result\n", "final\n")
        self.dirty_checkout()
        before = self.checkout_snapshot(self.repo, UTM_TARGET)
        with self.assertRaises(subprocess.CalledProcessError):
            verifier.verify_patches_directory(self.patches, utm_repo=self.repo)
        self.assertEqual(self.checkout_snapshot(self.repo, UTM_TARGET), before)

    def test_repositories_receive_only_their_own_stack(self) -> None:
        display = self.create_repo("display", DISPLAY_TARGET)
        self.write_patch("01.patch", UTM_TARGET, "base\n", "engine\n")
        self.write_patch("02-cocoaspice.patch", DISPLAY_TARGET, "base\n", "display\n")
        before = self.checkout_snapshot(self.repo, UTM_TARGET)
        display_before = self.checkout_snapshot(display, DISPLAY_TARGET)
        report = verifier.verify_patches_directory(self.patches, self.repo, display)
        checks = report["git_apply_checks"]
        self.assertEqual(checks["utm_ordered_apply_checks"], 1)
        self.assertEqual(checks["cocoaspice_ordered_apply_checks"], 1)
        self.assertEqual(self.checkout_snapshot(self.repo, UTM_TARGET), before)
        self.assertEqual(self.checkout_snapshot(display, DISPLAY_TARGET), display_before)


if __name__ == "__main__":
    unittest.main()

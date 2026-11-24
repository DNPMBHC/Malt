"""Compile MetalFX experiment sources against the active macOS SDK."""

from __future__ import annotations

import platform
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE_NAMES = (
    "HostMetalFXBenchmark.swift",
    "HostMetalFXBenchmarkGPUContext.swift",
    "HostMetalFXBenchmarkGPUPath.swift",
)
IGNORED_DIRECTORIES = {".build", ".git", "DerivedData", "node_modules"}


def _is_generated(path: Path, root: Path) -> bool:
    return any(part in IGNORED_DIRECTORIES for part in path.relative_to(root).parts)


def _discover_sources(root: Path) -> list[Path]:
    projects = [path for path in root.rglob("*.xcodeproj")
                if path.is_dir() and not _is_generated(path, root)]
    if len(projects) != 1:
        raise ValueError(f"expected exactly one Xcode project, found {len(projects)}")

    package_manifests = [path for path in projects[0].parent.rglob("Package.swift")
                         if not _is_generated(path, root)]
    if len(package_manifests) != 1:
        raise ValueError(f"expected exactly one local Swift package, found {len(package_manifests)}")

    package_root = package_manifests[0].parent
    sources = []
    for name in SOURCE_NAMES:
        matches = [path for path in package_root.rglob(name) if not _is_generated(path, root)]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one package source named {name}, found {len(matches)}")
        sources.append(matches[0])
    if len({path.parent for path in sources}) != 1:
        raise ValueError("MetalFX experiment sources must share one source directory")
    return sources


def _redact_path(text: str, path: Path | str, label: str) -> str:
    value = str(path)
    if not value:
        return text
    pattern = re.escape(value) + r"(?:[/\\][^\s\"'<>:)]*)*"
    return re.sub(pattern, label, text).replace(value, label)


def _redact_diagnostics(text: str, root: Path, temporary: Path, sdk_path: str) -> str:
    text = _redact_path(text, sdk_path, "<macOS SDK>")
    temporary_roots = {Path(tempfile.gettempdir()), Path(tempfile.gettempdir()).resolve(),
                        temporary, temporary.resolve()}
    for path in sorted(temporary_roots, key=lambda item: len(str(item)), reverse=True):
        text = _redact_path(text, path, "<temporary>")
    for path in sorted({Path.home(), Path.home().resolve()}, key=lambda item: len(str(item)), reverse=True):
        text = _redact_path(text, path, "<home>")
    return _redact_path(text, root.resolve(), "my-project")


class MetalFXSDKCompileTests(unittest.TestCase):
    @unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"),
                         "requires the macOS SDK and xcrun")
    def test_experiment_sources_typecheck_against_active_macos_sdk(self) -> None:
        root = Path(__file__).resolve().parents[1]
        try:
            sources = _discover_sources(root)
        except ValueError as error:
            self.fail(str(error))
        self.assertTrue(all(path.is_file() for path in sources), "MetalFX compile inputs are missing")

        sdk = subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            capture_output=True, text=True, check=False,
        )
        sdk_diagnostics = _redact_diagnostics(
            sdk.stdout + sdk.stderr, root, Path(tempfile.gettempdir()), ""
        )
        self.assertEqual(sdk.returncode, 0, sdk_diagnostics or "xcrun could not resolve the macOS SDK")
        sdk_path = sdk.stdout.strip()
        self.assertTrue(sdk_path, "xcrun returned an empty macOS SDK path")

        with tempfile.TemporaryDirectory(prefix="metalfx-sdk-typecheck-") as temporary_name:
            temporary = Path(temporary_name)
            result = subprocess.run(
                [
                    "xcrun", "swiftc", "-typecheck", "-sdk", sdk_path,
                    "-module-cache-path", str(temporary / "module-cache"),
                    *(str(path) for path in sources),
                ],
                capture_output=True, text=True, check=False,
            )
            if result.returncode:
                diagnostics = _redact_diagnostics(
                    result.stdout + result.stderr, root, temporary, sdk_path
                )
                self.fail(f"MetalFX sources failed macOS SDK typechecking:\n{diagnostics}")

    def test_failure_diagnostics_redact_home_and_temporary_paths(self) -> None:
        root = Path("/private/work/my-project")
        temporary = Path("/private/tmp/sdk-check")
        raw = (
            f"{root}/module/package/source.swift {Path.home()}/Library/cache"
            f" {temporary}/module-cache {Path(tempfile.gettempdir())}/nested/cache"
        )
        redacted = _redact_diagnostics(raw, root, temporary, "/Applications/SDKs/Current.sdk")
        for private_path in (str(root), str(Path.home()), str(temporary), str(Path(tempfile.gettempdir()))):
            self.assertNotIn(private_path, redacted)
        self.assertNotIn("module/package", redacted)
        self.assertIn("<home>", redacted)
        self.assertIn("<temporary>", redacted)


if __name__ == "__main__":
    unittest.main()

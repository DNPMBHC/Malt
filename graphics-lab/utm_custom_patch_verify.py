#!/usr/bin/env python3
"""Static compliance & git-apply verifier for Whisky/Modules/utm-custom patches.

Owner: @DNPMBHC
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATCHES_DIR = WORKSPACE_ROOT / "Whisky/Modules/utm-custom/patches"

ALLOWED_TARGET_PREFIXES = (
    "Services/UTMQemuVirtualMachine.swift",
    "Services/UTMQemuSystem.m",
    "Configuration/UTMQemuConfiguration+Arguments.swift",
    "Configuration/UTMQemuConfigurationInput.swift",
    "QEMUHelper/QEMUHelper.m",
    "Platform/macOS/Info.plist",
    "Platform/macOS/AppDelegate.swift",
    "Platform/macOS/Display/VMDisplayWindowController.swift",
    "Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift",
    "Platform/macOS/Display/VMMetalView.swift",
    "Sources/CocoaSpice/include/CSCursor.h",
    "Sources/CocoaSpice/CSCursor.m",
    "Sources/CocoaSpice/CSDisplay.m",
    "Sources/CocoaSpiceRenderer/include/CSMetalRenderer.h",
    "Sources/CocoaSpiceRenderer/CSMetalRenderer.m",
)

FORBIDDEN_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("cpuid_spoofing", re.compile(r"\bcpuid\b|hypervisor[-_ ]?present|hv[-_ ]?vendor", re.IGNORECASE)),
    ("smbios_or_acpi_spoofing", re.compile(r"\bsmbios\b|\bacpi\b|dmi[-_ ]?table|spoof", re.IGNORECASE)),
    ("tpm_or_secureboot_tampering", re.compile(r"tpm[-_ ]?spoof|disable[-_ ]?secure[-_ ]?boot|testsigning", re.IGNORECASE)),
    ("windows_kernel_or_driver", re.compile(r"viogpu3d\.sys|neptune_umd|System32\\|\.sys\b", re.IGNORECASE)),
    ("anticheat_or_game_tampering", re.compile(r"ACE-GAME|ACE-BASE|AntiCheatExpert|vanguard|\bvgc\b|\bvgk\b|hook_aim|auto_aim", re.IGNORECASE)),
)


def parse_patch_targets(patch_text: str) -> list[str]:
    targets: list[str] = []
    for line in patch_text.splitlines():
        if line.startswith("+++ b/"):
            targets.append(line[6:].strip())
    return targets


def audit_patch_text(name: str, patch_text: str) -> dict[str, Any]:
    targets = parse_patch_targets(patch_text)
    if not targets:
        raise ValueError(f"Patch '{name}' contains no modified target files")

    disallowed_targets = [
        target for target in targets if not any(target.startswith(prefix) for prefix in ALLOWED_TARGET_PREFIXES)
    ]
    if disallowed_targets:
        raise ValueError(f"Patch '{name}' modifies disallowed target(s): {disallowed_targets}")

    violations: list[str] = []
    for line in patch_text.splitlines():
        if not (line.startswith("+") or line.startswith("-")):
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        for rule_name, pattern in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                violations.append(f"{rule_name}: {line.strip()}")

    if violations:
        raise ValueError(f"Compliance violation in patch '{name}': {violations}")

    return {
        "name": name,
        "sha256": hashlib.sha256(patch_text.encode("utf-8")).hexdigest(),
        "targets": targets,
        "line_count": len(patch_text.splitlines()),
        "compliance_passed": True,
    }


def verify_patches_directory(
    patches_dir: Path = DEFAULT_PATCHES_DIR,
    utm_repo: Path | None = None,
    cocoaspice_repo: Path | None = None,
) -> dict[str, Any]:
    patch_files = sorted(patches_dir.glob("*.patch"))
    if not patch_files:
        raise ValueError(f"No .patch files found in {patches_dir}")

    results = [audit_patch_text(p.name, p.read_text(encoding="utf-8")) for p in patch_files]

    git_apply_checks: dict[str, Any] = {}
    if utm_repo is not None and utm_repo.is_dir():
        utm_patches = [str(p.resolve()) for p in patch_files if "cocoaspice" not in p.name]
        if utm_patches:
            for patch_path in utm_patches:
                subprocess.run(["git", "-C", str(utm_repo), "apply", "--check", patch_path], check=True)
            subprocess.run(["git", "-C", str(utm_repo), "apply", "--check", *utm_patches], check=True)
            git_apply_checks["utm_standalone_apply_checks"] = len(utm_patches)
            git_apply_checks["utm_stacked_apply_check"] = True
    if cocoaspice_repo is not None and cocoaspice_repo.is_dir():
        spice_patches = [str(p.resolve()) for p in patch_files if "cocoaspice" in p.name]
        if spice_patches:
            for patch_path in spice_patches:
                subprocess.run(["git", "-C", str(cocoaspice_repo), "apply", "--check", patch_path], check=True)
            subprocess.run(["git", "-C", str(cocoaspice_repo), "apply", "--check", *spice_patches], check=True)
            git_apply_checks["cocoaspice_standalone_apply_checks"] = len(spice_patches)
            git_apply_checks["cocoaspice_stacked_apply_check"] = True
            git_apply_checks["cocoaspice_apply_check"] = True

    return {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "patch_count": len(results),
        "patches": results,
        "git_apply_checks": git_apply_checks,
        "passed": True,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify UTM custom patch compliance (@DNPMBHC)")
    parser.add_argument("--patches-dir", type=Path, default=DEFAULT_PATCHES_DIR)
    parser.add_argument("--utm-repo", type=Path, default=None)
    parser.add_argument("--cocoaspice-repo", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    report = verify_patches_directory(
        patches_dir=args.patches_dir,
        utm_repo=args.utm_repo,
        cocoaspice_repo=args.cocoaspice_repo,
    )
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

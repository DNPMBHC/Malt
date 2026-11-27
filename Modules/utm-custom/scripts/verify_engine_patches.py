#!/usr/bin/env python3
"""Static compliance and application checks for engine patches.

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
import os
import tempfile
from typing import Any

DEFAULT_PATCHES_DIR = Path(__file__).resolve().parent.parent / "patches"

ALLOWED_TARGET_PREFIXES = (
    "utmctl/Info.plist",
    "utmctl/UTMCtl.swift",
    "utmctl/utmctl-unsigned.entitlements",
    "utmctl/utmctl.entitlements",
    "Services/UTMQemuVirtualMachine.swift",
    "Scripting/UTMScriptingVirtualMachineImpl.swift",
    "Services/UTMQemuSystem.m",
    "Configuration/UTMQemuConfiguration+Arguments.swift",
    "Configuration/UTMQemuConfigurationInput.swift",
    "QEMUHelper/QEMUHelper.m",
    "QEMULauncher/Bootstrap.c",
    "Platform/macOS/Info.plist",
    "Platform/macOS/AppDelegate.swift",
    "Platform/macOS/Display/VMDisplayWindowController.swift",
    "Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift",
    "Platform/macOS/Display/VMMetalView.swift",
    "Sources/CocoaSpice/include/CSCursor.h",
    "Sources/CocoaSpice/CSCursor.m",
    "Sources/CocoaSpice/CSDisplay.m",
    "Sources/CocoaSpice/CSInput.m",
    "Sources/CocoaSpice/CSMain.m",
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
        if line.startswith(("--- a/", "+++ b/")):
            target = line[6:].strip()
            if target not in targets:
                targets.append(target)
    return targets


def audit_patch_text(name: str, patch_text: str) -> dict[str, Any]:
    targets = parse_patch_targets(patch_text)
    if not targets:
        raise ValueError(f"Patch '{name}' contains no modified target files")

    disallowed_targets = [
        target for target in targets if target not in ALLOWED_TARGET_PREFIXES
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
    for label, repository, is_display in (
        ("utm", utm_repo, False),
        ("cocoaspice", cocoaspice_repo, True),
    ):
        if repository is None or not repository.is_dir():
            continue
        selected = [p for p in patch_files if ("cocoaspice" in p.name) == is_display]
        # A temporary Git index checks the ordered stack without changing the checkout.
        with tempfile.TemporaryDirectory(prefix="engine-patch-check-") as scratch:
            environment = os.environ.copy()
            environment["GIT_INDEX_FILE"] = str(Path(scratch) / "index")
            command = ["git", "-C", str(repository)]
            subprocess.run(command + ["read-tree", "HEAD"], env=environment, check=True)
            for patch in selected:
                subprocess.run(command + ["apply", "--cached", "--check", str(patch.resolve())],
                               env=environment, check=True)
                subprocess.run(command + ["apply", "--cached", str(patch.resolve())],
                               env=environment, check=True)
        git_apply_checks[label + "_ordered_apply_checks"] = len(selected)
        git_apply_checks[label + "_stacked_apply_check"] = True

    vmnet_bridge_src = next((patches_dir.parent / "vmnet-bridge").glob("*_vmnet_bridge.c"), None)
    vmnet_bridge_audit: dict[str, Any] | None = None
    if vmnet_bridge_src is not None and vmnet_bridge_src.is_file():
        src_text = vmnet_bridge_src.read_text(encoding="utf-8")
        src_violations: list[str] = []
        for rule_name, pattern in FORBIDDEN_PATTERNS:
            for ln in src_text.splitlines():
                if pattern.search(ln):
                    src_violations.append(f"{rule_name}: {ln.strip()}")
        if src_violations:
            raise ValueError(f"Compliance violation in vmnet-bridge source: {src_violations}")
        vmnet_bridge_audit = {
            "source_present": True,
            "sha256": hashlib.sha256(src_text.encode("utf-8")).hexdigest(),
            "plist_template_present": (patches_dir.parent / "vmnet-bridge" / "com.malt.vmnet-bridge.plist.template").is_file(),
            "installer_present": (patches_dir.parent / "vmnet-bridge" / "install_vmnet_bridge.sh").is_file(),
            "compliance_passed": True,
        }

    return {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "patch_count": len(results),
        "patches": results,
        "git_apply_checks": git_apply_checks,
        "vmnet_bridge_audit": vmnet_bridge_audit,
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

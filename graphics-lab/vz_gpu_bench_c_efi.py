#!/usr/bin/env python3
"""Consume real EFI frames with current downstream graphics sources. Owner: @DNPMBHC."""
from __future__ import annotations

import json
import hashlib
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import vz_gpu_bench_runner as runner
from vz_gpu_bench_efi import attach, build_guest, checked, detach
from vz_gpu_bench_library import LIBRARY_DIR, build_and_smoke

C_SOURCES = ("GuestSurfaceModels.swift", "GuestSurfaceDisplayModels.swift",
             "GuestSurfaceMetalPresenter.swift", "GuestSurfacePushFrameSource.swift")


def run() -> dict:
    package = next(runner.ROOT.glob("*/*/Package.swift")).parent
    runtime = next(package.glob("Sources/*/Runtime"))
    binding_path = runner.EVIDENCE / "producer-library-binding.json"
    binding = json.loads(binding_path.read_text()) if binding_path.exists() else {}
    library = LIBRARY_DIR / "libModuleX.a"
    if not library.exists() or runner.sha256_file(library) != binding.get("library_sha256") or not all(
            runner.sha256_file(runner.MODULE / name) == digest for name, digest in binding.get("sources", {}).items()):
        binding = build_and_smoke()
    source_bytes = {name: (runtime / name).read_bytes()
                    for name in (*C_SOURCES, "GuestSurfaceSession.swift")}
    before = {name: hashlib.sha256(value).hexdigest() for name, value in source_bytes.items()}
    with tempfile.TemporaryDirectory(prefix="demo-app-efi-c-interop-") as temporary:
        directory = Path(temporary)
        snapshot = directory / "consumer-sources"
        snapshot.mkdir()
        for name in C_SOURCES:
            (snapshot / name).write_bytes(source_bytes[name])
        declaration = re.search(r"public enum GuestSurfaceSessionError[^\{]+\{[^}]+\}",
                                source_bytes["GuestSurfaceSession.swift"].decode())
        if declaration is None:
            raise RuntimeError("Exact consumer error declaration unavailable")
        (snapshot / "ExactErrorDeclaration.swift").write_text(declaration.group(0) + "\n")
        consumer_library = directory / "libModuleC.a"
        checked(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-parse-as-library", "-emit-library", "-static",
                 "-emit-module", "-module-name", "ModuleC", "-emit-module-path", str(directory / "ModuleC.swiftmodule"),
                 "-module-cache-path", str(directory / "cache"),
                 *[str(p) for p in sorted(snapshot.glob("*.swift"))], "-o", str(consumer_library)])
        harness = runner.EVIDENCE / "efi-consumer-roundtrip.swift"
        harness_snapshot = directory / "harness.swift"
        harness_snapshot.write_bytes(harness.read_bytes())
        harness_digest = runner.sha256_file(harness_snapshot)
        executable = directory / "demo-app-efi-roundtrip"
        checked(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-parse-as-library", "-I", str(directory),
                 "-I", str(LIBRARY_DIR), "-L", str(directory), "-L", str(LIBRARY_DIR), "-lModuleC", "-lModuleX",
                 "-module-cache-path", str(directory / "cache"), str(harness_snapshot), "-o", str(executable)])
        checked(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
                 str(runner.MODULE / "vz_bridge.entitlements"), str(executable)])
        guest, fixture = build_guest(directory)
        runs = []
        for width, height in ((1280, 720), (2560, 1440)):
            for trial in (1, 2):
                image = directory / ("fixture-" + str(width) + "-" + str(trial) + ".dmg")
                mount = directory / "mount"
                checked(["hdiutil", "create", "-size", "64m", "-fs", "MS-DOS", "-volname", "DEMOEFI",
                         "-layout", "MBRSPUD", "-type", "UDIF", "-ov", str(image)])
                device = attach(image, mount)
                try:
                    boot = mount / "EFI/BOOT/BOOTAA64.EFI"
                    boot.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(guest, boot)
                finally:
                    detach(device)
                checks = json.loads(checked([str(executable), str(image), str(width), str(height)], timeout=75))
                runs.append({"resolution": [width, height], "trial": trial, "frames": 1, "checks": checks})
        stable = all(runner.sha256_file(runtime / name) == digest for name, digest in before.items())
        stable = stable and harness_digest == runner.sha256_file(harness) and all(
            runner.sha256_file(runner.MODULE / name) == digest for name, digest in binding["sources"].items())
        report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
                  "scope": "actual_downstream_graphics_subset_and_exact_error_declaration_not_complete_runtime",
                  "origin": "uefi_diagnostic_guest_commands_not_Windows_application_scanout",
                  "source_binding_authority": "local_immutable_compile_snapshot_with_pre_post_hashes",
                  "external_release_or_snapshot_status_claimed": False, "consumer_source_sha256": before,
                  "producer_library_binding": binding, "fixture": fixture, "harness_sha256": harness_digest,
                  "executable_sha256": runner.sha256_file(executable), "consumer_library_sha256": runner.sha256_file(consumer_library),
                  "inputs_stable": stable, "efi_vm_actions": 4, "shared_vm_actions": 0,
                  "frames_consumed": 4, "runs": runs, "real_efi_guest_commands_verified": True,
                  "gpu_all_pixels_equal": all(run["checks"].get("gpu_all_pixels_equal") for run in runs),
                  "gpu_comparison_readback_bytes_per_frame": 4, "visible_window_created": False,
                  "native_fullscreen_verified": False, "real_windows_scanout_verified": False,
                  "virtual_hid_verified": False, "production_game_backend_enabled": False,
                  "passed": stable and all(len(run["checks"]) >= 14 and all(run["checks"].values()) for run in runs)}
    runner.save_json(runner.EVIDENCE / "efi-downstream-consumer-roundtrip.json", report)
    if not report["passed"]:
        raise RuntimeError("Real EFI downstream interop rejected")
    return report


if __name__ == "__main__":
    try:
        result = run()
        print(json.dumps({"owner": "@DNPMBHC", "passed": result["passed"], "frames_consumed": result["frames_consumed"],
                          "checks_per_run": [len(row["checks"]) for row in result["runs"]]}))
    except (RuntimeError, OSError, ValueError) as error:
        print(runner.redact(type(error).__name__ + ": " + str(error), runner.ROOT))
        raise SystemExit(1) from None

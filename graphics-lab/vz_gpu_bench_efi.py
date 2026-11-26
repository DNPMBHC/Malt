#!/usr/bin/env python3
"""Real isolated EFI PCI/queue/shared-Metal experiment. Owner: @DNPMBHC."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import tempfile
from pathlib import Path

import vz_gpu_bench_runner as runner

CONSUMER_SOURCE = r'''import Foundation
import IOSurface
import Metal
import ModuleX

var checks: [String: Bool] = [:]
let report = try EFIGuestProbe.run(disk: URL(fileURLWithPath: CommandLine.arguments[1]),
    width: 1280, height: 720, sharedMemoryBytes: 256 * 1024 * 1024) { frame in
    checks["actual_guest_diagnostic_origin"] = frame.origin.hasPrefix("uefi_diagnostic_guest_commands")
    checks["surface_layout"] = IOSurfaceGetWidth(frame.surface) == frame.width
        && IOSurfaceGetBytesPerRow(frame.surface) == frame.bytesPerRow
    checks["producer_timeline_ready"] = frame.readyEvent.signaledValue >= frame.readyValue
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let command = queue.makeCommandBuffer() else { return }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: frame.width, height: frame.height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .renderTarget]
    guard let source = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0) else { return }
    checks["same_iosurface_imported"] = source.iosurface === frame.surface
    descriptor.storageMode = .private
    guard let destination = device.makeTexture(descriptor: descriptor) else { return }
    command.encodeWaitForEvent(frame.readyEvent, value: frame.readyValue)
    guard let blit = command.makeBlitCommandEncoder() else { return }
    blit.copy(from: source, to: destination)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    checks["consumer_gpu_completed"] = command.status == .completed
    if command.status == .completed {
        checks["release_after_gpu_read"] = frame.release()
        checks["release_idempotent"] = !frame.release()
    }
}
checks["guest_2048_draws"] = report.drawCalls == 2048
checks["source_matches_reference"] = report.pixelsMatchReference
checks["guest_stopped"] = report.guestStopped
let data = try JSONEncoder().encode(checks)
print(String(decoding: data, as: UTF8.self))
if checks.count != 10 || checks.values.contains(false) { exit(1) }
'''


def pe_linker() -> tuple[Path, list[str]]:
    for base in (Path("/opt/homebrew/opt/llvm/bin"), Path("/usr/local/opt/llvm/bin")):
        candidate = base / "lld-link"
        if candidate.is_file():
            return candidate, []
    candidates = sorted((Path.home() / ".rustup/toolchains").glob("*/lib/rustlib/*/bin/rust-lld"))
    if candidates:
        return candidates[-1], ["-flavor", "link"]
    raise RuntimeError("A local LLVM PE linker is required for the isolated EFI fixture")


def checked(arguments: list[str], timeout: int = 60, environment: dict | None = None) -> str:
    result = runner.capture(arguments, timeout=timeout, env=environment)
    if result.returncode:
        raise RuntimeError(runner.redact(result.stdout + result.stderr, runner.ROOT)[-2000:])
    return result.stdout


def build_guest(directory: Path) -> tuple[Path, dict]:
    source = runner.MODULE / "efi_fixture" / "DemoGuest.c"
    header = source.with_name("DemoUEFI.h")
    object_file = directory / "guest.obj"
    executable = directory / "BOOTAA64.EFI"
    checked(["xcrun", "clang", "--target=aarch64-pc-windows-msvc", "-std=c11", "-O2",
             "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fshort-wchar",
             "-Wall", "-Wextra", "-Werror", "-c", str(source), "-o", str(object_file)])
    linker, flavor = pe_linker()
    environment = None
    if linker.name == "rust-lld":
        environment = dict(os.environ, DYLD_LIBRARY_PATH=str(linker.parents[4] / "lib"))
    checked([str(linker), *flavor, "/subsystem:efi_application", "/entry:efi_main", "/machine:arm64",
             "/nodefaultlib", "/out:" + str(executable), str(object_file)], environment=environment)
    return executable, {"guest_source_sha256": runner.sha256_file(source),
                        "guest_header_sha256": runner.sha256_file(header),
                        "guest_executable_sha256": runner.sha256_file(executable)}


def attach(image: Path, mount: Path) -> str:
    mount.mkdir(exist_ok=True)
    output = checked(["hdiutil", "attach", str(image), "-mountpoint", str(mount), "-nobrowse",
                      "-noverify", "-noautoopen", "-plist"])
    entities = plistlib.loads(output.encode())["system-entities"]
    return next(item["dev-entry"] for item in entities if "mount-point" in item)


def detach(device: str) -> None:
    checked(["hdiutil", "detach", device])


def run_case(directory: Path, executable: Path, width: int, height: int,
             region_bytes: int = 256 * 1024 * 1024) -> dict:
    image = directory / "fixture.dmg"
    mount = directory / "mount"
    checked(["hdiutil", "create", "-size", "64m", "-fs", "MS-DOS", "-volname", "DEMOEFI",
             "-layout", "MBRSPUD", "-type", "UDIF", "-ov", str(image)])
    device = attach(image, mount)
    try:
        destination = mount / "EFI/BOOT/BOOTAA64.EFI"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(executable, destination)
    finally:
        detach(device)
    native = runner.run_mode("efi-guest-probe", ["--fixture-disk", str(image), "--width", str(width),
                                                "--height", str(height), "--region-bytes", str(region_bytes)], timeout=75)
    device = attach(image, mount)
    try:
        result_file = mount / "RESULT.JSON"
        guest = json.loads(result_file.read_text()) if result_file.is_file() else None
    finally:
        detach(device)
    checks = {
        "native_configuration_validated": native["configurationValidated"],
        "guest_started_and_stopped": native["guestStarted"] and native["guestStopped"],
        "driver_ok_observed": native["driverOkObserved"],
        "control_and_cursor_notified": native["controlElements"] > 0 and native["cursorElements"] > 0,
        "guest_ring_writes_reached_host": native["guestSharedMemoryWriteObserved"],
        "same_shared_command_memory": native["sameVZAndMetalCommandMemory"],
        "gpu_byte_exact_reference": native["pixelsMatchReference"],
        "guest_report_available": guest is not None,
    }
    if guest is not None:
        checks.update(pci_vendor_and_device=guest["vendorID"] == 0x1AF4 and guest["deviceID"] == 0x1050,
                      pci_display_class=guest["pciClass"] == 3,
                      dual_queues=guest["queueCount"] == 2,
                      modern_driver_negotiation=guest["versionOneNegotiated"] == 1 and guest["driverOk"] == 1
                      and guest["featuresOkDeviceStatus"] == 11 and guest["finalDeviceStatus"] == 15,
                      both_queues_completed=guest["controlCompleted"] == 1 and guest["cursorCompleted"] == 1,
                      display_reply=guest["controlReplyType"] == 0x1101,
                      standard_shm_id=guest["sharedMemoryRegionID"] == 1,
                      all_guest_commands_written=guest["guestDrawCommandsWritten"] == 2048,
                      guest_status_ok=guest["status"] == 0)
    return {"resolution": [width, height], "native": native, "guest": guest,
            "checks": checks, "passed": all(checks.values())}


def run_external_consumer(directory: Path, executable: Path) -> dict:
    from vz_gpu_bench_library import LIBRARY_DIR, build_and_smoke
    binding = build_and_smoke()
    image = directory / "consumer-fixture.dmg"
    mount = directory / "consumer-mount"
    checked(["hdiutil", "create", "-size", "64m", "-fs", "MS-DOS", "-volname", "DEMOEFI",
             "-layout", "MBRSPUD", "-type", "UDIF", "-ov", str(image)])
    device = attach(image, mount)
    try:
        destination = mount / "EFI/BOOT/BOOTAA64.EFI"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(executable, destination)
    finally:
        detach(device)
    source = directory / "main.swift"
    source.write_text(CONSUMER_SOURCE)
    consumer = directory / "demo-app-efi-consumer"
    checked(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-I", str(LIBRARY_DIR),
             "-L", str(LIBRARY_DIR), "-lModuleX", str(source), "-o", str(consumer)])
    checked(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
             str(runner.MODULE / "vz_bridge.entitlements"), str(consumer)])
    result = json.loads(checked([str(consumer), str(image)], timeout=75))
    report = {"owner": "@DNPMBHC", "origin": "uefi_diagnostic_guest_commands_not_Windows_application_scanout",
              "checks": result, "passed": all(result.values()), "hardened_runtime": True,
              "virtualization_entitlement": True, "real_windows_scanout_verified": False,
              "virtual_hid_verified": False, "consumer_sha256": runner.sha256_file(consumer),
              "consumer_source_sha256": runner.sha256_file(source), "library_binding": binding}
    runner.save_json(runner.EVIDENCE / "efi-guest-external-consumer.json", report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--external-consumer", action="store_true")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--region-bytes", type=int, default=256 * 1024 * 1024)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="demo-app-efi-guest-") as temporary:
        directory = Path(temporary)
        executable, binding = build_guest(directory)
        report = {"owner": "@DNPMBHC", "scope": "isolated_UEFI_not_Windows_WDDM_Venus",
                  "ordinary_virtualization_entitlement": True, "hardened_runtime": True,
                  "real_windows_scanout_verified": False, "virtual_hid_verified": False,
                  "guest_fixture_secure_boot_enrolled": False, **binding}
        if not args.build_only:
            case = run_external_consumer(directory, executable) if args.external_consumer else run_case(
                directory, executable, args.width, args.height, args.region_bytes)
            report.update(case)
        report["native_binary_sha256"] = runner.sha256_file(runner.BINARY)
        name = "efi-guest-build.json" if args.build_only else "efi-guest-" + str(args.width) + ".json"
        if args.external_consumer:
            name = "efi-guest-external-consumer.json"
        runner.save_json(runner.EVIDENCE / name, report)
        print(json.dumps({"owner": "@DNPMBHC", "evidence": name, "build_only": args.build_only,
                          "passed": report.get("passed"), "checks": report.get("checks", {})}))
        return 0 if args.build_only or report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(runner.redact(type(error).__name__ + ": " + str(error), runner.ROOT))
        raise SystemExit(1) from None

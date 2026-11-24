// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import IOSurface
import Metal
import ModuleC
import ModuleX

private enum ProbeError: Error {
    case unavailable
}

private final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [String: Bool] = [:]
    private var returned = false

    func check(_ name: String, _ passed: Bool) {
        lock.lock()
        flags[name] = (flags[name] ?? true) && passed
        lock.unlock()
    }

    var checks: [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return flags
    }

    var isReturned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returned
    }

    func wrap(_ lease: EFIGuestSurfaceLease) -> GuestSurfaceFrame {
        check("efi_origin_explicit", lease.origin == "uefi_diagnostic_guest_commands_not_Windows_application_scanout")
        check("stride_matches", IOSurfaceGetBytesPerRow(lease.surface) == lease.bytesPerRow)
        check("write_timeline_completed", lease.readyEvent.signaledValue >= lease.readyValue)
        return GuestSurfaceFrame(
            descriptor: GuestSurfaceFrameDescriptor(
                frameID: 1, width: lease.width, height: lease.height,
                pixelFormat: .bgra8Unorm, ioSurfaceID: IOSurfaceGetID(lease.surface),
                sharedEventSignaledValue: lease.readyValue, backend: .unavailable
            ),
            surface: lease.surface, sharedEvent: lease.readyEvent,
            onRelease: { [self] in acknowledge(lease) }
        )
    }

    private func acknowledge(_ lease: EFIGuestSurfaceLease) {
        check("producer_release_once", lease.release())
        check("producer_release_idempotent", !lease.release())
        lock.lock()
        returned = true
        lock.unlock()
    }
}

private final class Comparator {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void comparePixels(texture2d<float, access::read> first [[texture(0)]],
            texture2d<float, access::read> second [[texture(1)]],
            device atomic_uint *failures [[buffer(0)]], uint2 pixel [[thread_position_in_grid]]) {
            if (pixel.x >= first.get_width() || pixel.y >= first.get_height()) return;
            if (any(first.read(pixel) != second.read(pixel))) {
                atomic_fetch_add_explicit(failures, 1, memory_order_relaxed);
            }
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        guard let function = library.makeFunction(name: "comparePixels") else { throw ProbeError.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func encode(source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws -> MTLBuffer {
        guard let result = device.makeBuffer(length: 4, options: .storageModeShared),
              let encoder = command.makeComputeCommandEncoder() else { throw ProbeError.unavailable }
        result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return result
    }
}

@main
private struct Probe {
    static func main() async {
        do {
            try await run()
        } catch {
            print("{\"passed\":false,\"owner\":\"@DNPMBHC\",\"error\":\"efi_interop_failed\"}")
            exit(1)
        }
    }

    private static func run() async throws {
        let disk = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let width = Int(CommandLine.arguments[2]), let height = Int(CommandLine.arguments[3]),
              let device = MTLCreateSystemDefaultDevice() else { throw ProbeError.unavailable }
        let ledger = Ledger()
        let presenter = try GuestSurfaceMetalPresenter(device: device)
        let comparator = try Comparator(device: device)
        let pair = AsyncStream<GuestSurfaceFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let push = GuestSurfacePushFrameSource(backend: .unavailable)
        try await push.start { frame in
            if case .dropped(let old) = pair.continuation.yield(frame) { old.release() }
        }
        let native = try await Task.detached {
            try EFIGuestProbe.run(disk: disk, width: width, height: height,
                                  sharedMemoryBytes: 256 * 1024 * 1024) { lease in
                ledger.check("push_adapter_accepted", push.publish(ledger.wrap(lease)))
            }
        }.value
        pair.continuation.finish()
        var count = 0
        for await frame in pair.stream {
            try await render(frame, presenter: presenter, comparator: comparator, ledger: ledger)
            count += 1
        }
        await push.stop()
        ledger.check("one_actual_guest_frame", count == 1)
        ledger.check("guest_2048_draws", native.drawCalls == 2048)
        ledger.check("guest_stopped", native.guestStopped)
        ledger.check("guest_pixels_match_reference", native.pixelsMatchReference)
        ledger.check("all_leases_released", ledger.isReturned)
        let data = try JSONEncoder().encode(ledger.checks)
        guard let encoded = String(data: data, encoding: .utf8) else { throw ProbeError.unavailable }
        print(encoded)
        if ledger.checks.values.contains(false) { exit(1) }
    }

    private static func render(_ frame: GuestSurfaceFrame, presenter: GuestSurfaceMetalPresenter,
                               comparator: Comparator, ledger: Ledger) async throws {
        guard await frame.waitForProducer() else { throw ProbeError.unavailable }
        let source = try GuestSurfaceTextureBinding.makeTexture(for: frame, device: presenter.device)
        ledger.check("same_iosurface_imported", source.iosurface === frame.surface)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: frame.descriptor.width, height: frame.descriptor.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let target = presenter.device.makeTexture(descriptor: descriptor) else { throw ProbeError.unavailable }
        let command = try presenter.encode(frame, target: target)
        let difference = try comparator.encode(source: source, target: target, command: command)
        ledger.check("retained_until_gpu_submission", !ledger.isReturned)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        ledger.check("consumer_gpu_completed", command.status == .completed)
        frame.release()
        for _ in 0..<100 where !ledger.isReturned {
            try await Task.sleep(for: .milliseconds(1))
        }
        ledger.check("gpu_all_pixels_equal", difference.contents().load(as: UInt32.self) == 0)
        ledger.check("released_after_gpu_read", ledger.isReturned)
    }
}

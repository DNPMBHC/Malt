// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import CryptoKit
import Foundation
import IOSurface
import Metal

private final class ProbeFrameStore {
    private let lock = NSLock()
    private var storage: [SurfaceFrameLease] = []

    func append(_ frame: SurfaceFrameLease) {
        lock.lock()
        storage.append(frame)
        lock.unlock()
    }

    var frames: [SurfaceFrameLease] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@available(macOS 27.0, *)
public enum SurfaceProducerProbe {
    public static func run() throws -> [String: Bool] {
        let producer = try SurfaceFrameProducer(width: 64, height: 64, draws: 64)
        let store = ProbeFrameStore()
        producer.start { store.append($0) }
        guard waitFor({ producer.snapshot()["dropped", default: 0] > 0 }) else {
            throw NSError(domain: "ProducerProbe", code: 1)
        }
        try stop(producer)
        let frames = store.frames
        guard frames.count == 3 else { throw NSError(domain: "ProducerProbe", code: 2) }
        let hashes = try frames.map(imageHash)
        let retainedHash = try imageHash(frames[2])
        var checks = initialChecks(frames: frames, snapshot: producer.snapshot())
        checks["gpu_consumer_completion_releases_lease"] = try consumeOnGPU(frames[0])
        checks["release_receipt_idempotent"] = !frames[0].release()
        let nextFrames = try resizeAndRestart(producer)
        checks["resize_generation_and_dimensions"] = nextFrames.allSatisfy {
            $0.metadata.generation == 2 && $0.metadata.width == 96 && $0.metadata.height == 64
        }
        checks["frame_id_strictly_increasing_after_restart"] =
            nextFrames[0].metadata.frameID > frames[2].metadata.frameID
        checks["old_surface_retained_across_resize"] = try imageHash(frames[2]) == retainedHash
        checks["leased_surface_not_overwritten"] = try frames.map(imageHash) == hashes
        for frame in frames.dropFirst() { frame.release() }
        for frame in nextFrames { frame.release() }
        checks["all_leases_returned"] = waitFor { producer.snapshot()["released"] == 6 }
        checks["pool_reusable_after_release"] = producer.snapshot()["leased"] == 0
        checks["producer_origin_explicitly_synthetic"] = frames.allSatisfy {
            $0.metadata.origin == "host_synthetic_not_guest_scanout"
        }
        return checks
    }

    private static func initialChecks(frames: [SurfaceFrameLease], snapshot: [String: UInt64]) -> [String: Bool] {
        ["bounded_three_surface_pool": snapshot["leased"] == 3 && snapshot["pool_size"] == 3,
         "backpressure_drops_instead_of_overwrite": snapshot["dropped", default: 0] > 0,
         "ready_timeline_reached": frames.allSatisfy { $0.readyEvent.signaledValue >= $0.metadata.readyValue },
         "actual_surface_metadata_matches": frames.allSatisfy {
             IOSurfaceGetWidth($0.surface) == $0.metadata.width && IOSurfaceGetHeight($0.surface) == $0.metadata.height
                 && IOSurfaceGetBytesPerRow($0.surface) == $0.metadata.bytesPerRow
                 && lookupMatches($0.surface)
         },
         "no_render_failure": snapshot["failures"] == 0]
    }

    private static func lookupMatches(_ surface: IOSurfaceRef) -> Bool {
        let identifier = IOSurfaceGetID(surface)
        guard let found = IOSurfaceLookup(identifier) else { return false }
        return IOSurfaceGetID(found) == identifier
            && IOSurfaceGetWidth(found) == IOSurfaceGetWidth(surface)
            && IOSurfaceGetBytesPerRow(found) == IOSurfaceGetBytesPerRow(surface)
    }

    private static func stop(_ producer: SurfaceFrameProducer) throws {
        let wait = DispatchSemaphore(value: 0)
        producer.stop { wait.signal() }
        guard wait.wait(timeout: .now() + 12) == .success else {
            throw NSError(domain: "ProducerProbeStop", code: 1)
        }
    }

    private static func resizeAndRestart(_ producer: SurfaceFrameProducer) throws -> [SurfaceFrameLease] {
        let wait = DispatchSemaphore(value: 0)
        var resized = false
        producer.resize(width: 96, height: 64) { result in
            resized = result
            wait.signal()
        }
        guard wait.wait(timeout: .now() + 12) == .success, resized else {
            throw NSError(domain: "ProducerProbeResize", code: 1)
        }
        let store = ProbeFrameStore()
        producer.start { store.append($0) }
        guard waitFor({ store.frames.count == 3 }) else { throw NSError(domain: "ProducerProbe", code: 3) }
        try stop(producer)
        return store.frames
    }

    private static func texture(_ frame: SurfaceFrameLease, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: frame.metadata.width, height: frame.metadata.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0) else {
            throw NSError(domain: "ProducerProbeTexture", code: 1)
        }
        return texture
    }

    private static func imageHash(_ frame: SurfaceFrameLease) throws -> String {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "ProducerProbe", code: 4) }
        let source = try texture(frame, device: device)
        var bytes = [UInt8](repeating: 0, count: frame.metadata.width * frame.metadata.height * 4)
        source.getBytes(&bytes, bytesPerRow: frame.metadata.width * 4,
                        from: MTLRegionMake2D(0, 0, frame.metadata.width, frame.metadata.height), mipmapLevel: 0)
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func consumeOnGPU(_ frame: SurfaceFrameLease) throws -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer(),
              let target = device.makeBuffer(length: frame.metadata.bytesPerRow * frame.metadata.height),
              let encoder = command.makeBlitCommandEncoder() else {
            throw NSError(domain: "ProducerProbeGPU", code: 1)
        }
        let source = try texture(frame, device: device)
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: frame.metadata.width, height: frame.metadata.height, depth: 1),
            to: target, destinationOffset: 0, destinationBytesPerRow: frame.metadata.bytesPerRow,
            destinationBytesPerImage: target.length)
        encoder.endEncoding()
        let wait = DispatchSemaphore(value: 0)
        var released = false
        command.addCompletedHandler { completed in
            released = completed.status == .completed && frame.release()
            wait.signal()
        }
        command.commit()
        return wait.wait(timeout: .now() + 10) == .success && released
    }

    private static func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 12)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}

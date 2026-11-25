// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation
import IOSurface
import Metal
import ModuleC
import ModuleX

private enum ProbeError: Error {
  case failed(String)
}

private final class LeaseLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var returned: Set<UInt64> = []
  private var flags: [String: Bool] = [:]

  func check(_ name: String, _ passed: Bool) {
    lock.lock()
    flags[name] = (flags[name] ?? true) && passed
    lock.unlock()
  }

  func didReturn(_ id: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return returned.contains(id)
  }

  var checks: [String: Bool] {
    lock.lock()
    defer { lock.unlock() }
    return flags
  }

  func wrap(_ lease: SurfaceFrameLease) -> GuestSurfaceFrame {
    let metadata = lease.metadata
    check("origin_explicitly_synthetic", metadata.origin == "host_synthetic_not_guest_scanout")
    check("supported_format", metadata.pixelFormat == "BGRA8Unorm")
    check("layout_matches_producer", IOSurfaceGetBytesPerRow(lease.surface) == metadata.bytesPerRow)
    check("producer_write_complete", lease.readyEvent.signaledValue >= metadata.readyValue)
    return GuestSurfaceFrame(
      descriptor: GuestSurfaceFrameDescriptor(
        frameID: metadata.frameID, width: metadata.width, height: metadata.height,
        pixelFormat: .bgra8Unorm, ioSurfaceID: IOSurfaceGetID(lease.surface),
        sharedEventSignaledValue: metadata.readyValue, backend: .syntheticTest),
      surface: lease.surface, sharedEvent: lease.readyEvent,
      onRelease: { [self] in acknowledge(lease) })
  }

  private func acknowledge(_ lease: SurfaceFrameLease) {
    let first = lease.release()
    let repeated = lease.release()
    check("producer_release_idempotent", first && !repeated)
    lock.lock()
    let inserted = returned.insert(lease.metadata.frameID).inserted
    lock.unlock()
    check("consumer_receipt_once_per_frame", inserted)
  }
}

private final class GPUComparator {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    self.device = device
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    guard let function = library.makeFunction(name: "comparePixels") else { throw ProbeError.failed("shader_missing") }
    pipeline = try device.makeComputePipelineState(function: function)
  }

  func encode(source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws -> MTLBuffer {
    guard let result = device.makeBuffer(length: 4, options: .storageModeShared),
      let encoder = command.makeComputeCommandEncoder()
    else { throw ProbeError.failed("comparison_unavailable") }
    result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(target, index: 1)
    encoder.setBuffer(result, offset: 0, index: 0)
    encoder.dispatchThreads(
      MTLSize(width: source.width, height: source.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    return result
  }

  private static let shader = """
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
}

private struct ProbeResult: Encodable {
  let owner = "@DNPMBHC"
  let sourceOrigin = "host_synthetic_not_guest_scanout"
  let nativeFullscreenVerified = false
  let realGuestVerified = false
  let virtualHIDVerified = false
  let framesConsumed: Int
  let checks: [String: Bool]
  let producerSnapshot: [String: UInt64]
}

@main
private struct RoundtripProbe {
  static func main() async {
    do {
      let result = try await run()
      let data = try JSONEncoder().encode(result)
      guard let encoded = String(data: data, encoding: .utf8) else { throw ProbeError.failed("invalid_utf8") }
      print(encoded)
      exit(result.checks.values.allSatisfy { $0 } ? 0 : 1)
    } catch {
      print("{\"owner\":\"@DNPMBHC\",\"passed\":false,\"error\":\"roundtrip_failed\"}")
      exit(1)
    }
  }

  private static func run() async throws -> ProbeResult {
    guard let device = MTLCreateSystemDefaultDevice() else { throw ProbeError.failed("metal_unavailable") }
    let presenter = try GuestSurfaceMetalPresenter(device: device)
    let comparator = try GPUComparator(device: device)
    let producer = try SurfaceFrameProducer(width: 64, height: 64, draws: 64)
    let ledger = LeaseLedger()
    let push = GuestSurfacePushFrameSource(backend: .syntheticTest)
    let pair = AsyncStream<GuestSurfaceFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    try await push.start { frame in
      switch pair.continuation.yield(frame) {
      case .dropped(let discarded): discarded.release()
      case .terminated: frame.release()
      case .enqueued: break
      @unknown default: frame.release()
      }
    }
    producer.start { push.publish(ledger.wrap($0)) }
    let count = try await consume(
      pair.stream, producer: producer, presenter: presenter, comparator: comparator, ledger: ledger)
    await push.stop()
    await withCheckedContinuation { continuation in producer.stop { continuation.resume() } }
    pair.continuation.finish()
    for await remaining in pair.stream { remaining.release() }
    let snapshot = producer.snapshot()
    ledger.check("all_producer_leases_returned", snapshot["leased"] == 0)
    ledger.check("no_producer_render_failure", snapshot["failures"] == 0)
    ledger.check("consumer_rendered_twelve_frames", count == 12)
    return ProbeResult(framesConsumed: count, checks: ledger.checks, producerSnapshot: snapshot)
  }

  private static func consume(
    _ stream: AsyncStream<GuestSurfaceFrame>, producer: SurfaceFrameProducer,
    presenter: GuestSurfaceMetalPresenter, comparator: GPUComparator, ledger: LeaseLedger
  ) async throws -> Int {
    var count = 0
    var previousID: UInt64 = 0
    var resized = false
    for await frame in stream {
      ledger.check("frame_id_increases", frame.descriptor.frameID > previousID)
      previousID = frame.descriptor.frameID
      try await render(frame, presenter: presenter, comparator: comparator, ledger: ledger)
      count += 1
      if frame.descriptor.width == 96 && frame.descriptor.height == 48 { resized = true }
      if count == 4 {
        let changed = await withCheckedContinuation { continuation in
          producer.resize(width: 96, height: 48) { continuation.resume(returning: $0) }
        }
        ledger.check("producer_resize_succeeded", changed)
      }
      if count == 12 { break }
    }
    ledger.check("resized_frames_imported_by_consumer", resized)
    return count
  }

  private static func render(
    _ frame: GuestSurfaceFrame, presenter: GuestSurfaceMetalPresenter, comparator: GPUComparator, ledger: LeaseLedger
  ) async throws {
    guard await frame.waitForProducer() else { throw ProbeError.failed("producer_not_ready") }
    let source = try GuestSurfaceTextureBinding.makeTexture(for: frame, device: presenter.device)
    guard let surface = source.iosurface else { throw ProbeError.failed("import_lost_surface") }
    ledger.check("same_iosurface_imported", IOSurfaceGetID(surface) == frame.descriptor.ioSurfaceID)
    ledger.check("shared_texture_storage", source.storageMode == .shared)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: frame.descriptor.width, height: frame.descriptor.height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    guard let target = presenter.device.makeTexture(descriptor: descriptor) else {
      throw ProbeError.failed("target_unavailable")
    }
    let command = try presenter.encode(frame, target: target)
    let comparison = try comparator.encode(source: source, target: target, command: command)
    ledger.check("not_released_before_gpu_commit", !ledger.didReturn(frame.descriptor.frameID))
    await withCheckedContinuation { continuation in
      command.addCompletedHandler { _ in continuation.resume() }
      command.commit()
    }
    ledger.check("consumer_gpu_completed", command.status == .completed)
    frame.release()
    for _ in 0..<100 where !ledger.didReturn(frame.descriptor.frameID) {
      try await Task.sleep(for: .milliseconds(1))
    }
    ledger.check("released_after_gpu_completion", ledger.didReturn(frame.descriptor.frameID))
    let differences = comparison.contents().load(as: UInt32.self)
    ledger.check("gpu_byte_exact_pixels", differences == 0)
  }
}

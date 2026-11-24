// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface
import Metal
import XCTest

private final class FrameReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

final class GuestSurfaceFrameContractTests: XCTestCase {
  private func frame(width: Int = 8, height: Int = 8) async throws -> GuestSurfaceTestTypes.Frame {
    let source = GuestSurfaceTestTypes.SyntheticSource(width: width, height: height)
    let pair = AsyncStream<GuestSurfaceTestTypes.Frame>.makeStream()
    try await source.start {
      pair.continuation.yield($0)
      pair.continuation.finish()
    }
    var iterator = pair.stream.makeAsyncIterator()
    let next = await iterator.next()
    let result = try XCTUnwrap(next)
    await source.stop()
    return result
  }

  func testFrameReleaseIsExactlyOnceUnderConcurrentAcknowledgments() {
    let counter = FrameReleaseCounter()
    let frame = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 8, height: 8, backend: .syntheticTest),
      onRelease: { counter.increment() })
    DispatchQueue.concurrentPerform(iterations: 100) { _ in frame.release() }
    XCTAssertEqual(counter.count, 1)
  }

  func testRejectsSurfaceIdentityDimensionsAndMissingTimelineValue() async throws {
    let valid = try await frame()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let dimensions = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 9, height: 8,
        ioSurfaceID: valid.descriptor.ioSurfaceID, backend: .syntheticTest), surface: valid.surface)
    XCTAssertThrowsError(
      try GuestSurfaceTestTypes.TextureBinding.makeTexture(for: dimensions, device: device)
    ) {
      XCTAssertEqual($0 as? GuestSurfaceTestTypes.BindingError, .invalidDimensions)
    }
    let identity = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 8, height: 8,
        ioSurfaceID: 0, backend: .syntheticTest), surface: valid.surface)
    XCTAssertThrowsError(try GuestSurfaceTestTypes.TextureBinding.makeTexture(for: identity, device: device)) {
      XCTAssertEqual($0 as? GuestSurfaceTestTypes.BindingError, .surfaceIdentityMismatch)
    }
    let timeline = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 8, height: 8,
        ioSurfaceID: valid.descriptor.ioSurfaceID, backend: .syntheticTest),
      surface: valid.surface, sharedEvent: device.makeSharedEvent())
    XCTAssertThrowsError(try GuestSurfaceTestTypes.TextureBinding.makeTexture(for: timeline, device: device)) {
      XCTAssertEqual($0 as? GuestSurfaceTestTypes.BindingError, .incompleteSynchronization)
    }
  }

  func testImportedIOSurfaceRendersPixelExactlyAndReleasesAfterGPUCompletion() async throws {
    let input = try await frame()
    let surface = try XCTUnwrap(input.surface)
    IOSurfaceLock(surface, [], nil)
    let base = try XCTUnwrap(IOSurfaceGetBaseAddress(surface)).assumingMemoryBound(to: UInt8.self)
    let rowStride = IOSurfaceGetBytesPerRow(surface)
    for row in 0..<8 {
      for column in 0..<8 {
        let expected = [UInt8(column * 17 + 11), UInt8(row * 19 + 23), UInt8((row + column) * 13 + 31), 255]
        for (offset, value) in expected.enumerated() {
          base[row * rowStride + column * 4 + offset] = value
        }
      }
    }
    IOSurfaceUnlock(surface, [], nil)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let event = try XCTUnwrap(device.makeSharedEvent())
    event.signaledValue = 1
    let counter = FrameReleaseCounter()
    let synchronized = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 2, width: 8, height: 8,
        ioSurfaceID: input.descriptor.ioSurfaceID, sharedEventSignaledValue: 1,
        backend: .syntheticTest),
      surface: surface, sharedEvent: event, onRelease: { counter.increment() })
    let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
    outputDescriptor.storageMode = .shared
    outputDescriptor.usage = [.renderTarget, .shaderRead]
    let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
    let presenter = try GuestSurfaceTestTypes.MetalPresenter(device: device)
    let command = try presenter.encode(synchronized, target: output)
    XCTAssertEqual(counter.count, 0)
    await withCheckedContinuation { continuation in
      command.addCompletedHandler { _ in continuation.resume() }
      command.commit()
    }
    XCTAssertEqual(command.status, .completed)
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    output.getBytes(&pixels, bytesPerRow: 8 * 4, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let row = offset / (8 * 4)
      let column = (offset / 4) % 8
      let expected = [UInt8(column * 17 + 11), UInt8(row * 19 + 23), UInt8((row + column) * 13 + 31), 255]
      XCTAssertEqual(Array(pixels[offset..<offset + 4]), expected)
    }
    XCTAssertEqual(counter.count, 1)
  }
  func testUnsignaledProducerFenceTimesOutAndCanThenBecomeReady() async throws {
    let original = try await frame()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let event = try XCTUnwrap(device.makeSharedEvent())
    let synchronized = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 3, width: 8, height: 8,
        ioSurfaceID: original.descriptor.ioSurfaceID, sharedEventSignaledValue: 2, backend: .syntheticTest),
      surface: original.surface, sharedEvent: event)
    let timedOut = await synchronized.waitForProducer(timeoutMilliseconds: 10)
    XCTAssertFalse(timedOut)
    event.signaledValue = 2
    let ready = await synchronized.waitForProducer(timeoutMilliseconds: 10)
    XCTAssertTrue(ready)
  }

  func testCancelledProducerWaitReturnsWithoutWaitingForAnUnsignaledEvent() async throws {
    let original = try await frame()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let event = try XCTUnwrap(device.makeSharedEvent())
    let synchronized = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 4, width: 8, height: 8, ioSurfaceID: original.descriptor.ioSurfaceID,
        sharedEventSignaledValue: 9, backend: .syntheticTest),
      surface: original.surface, sharedEvent: event)
    let wait = Task { await synchronized.waitForProducer(timeoutMilliseconds: 5000) }
    wait.cancel()
    let ready = await wait.value
    XCTAssertFalse(ready)
  }

  func testPushAdapterRejectsStaleBackendAndStoppedFramesWithReleaseAcknowledgments() async throws {
    let source = GuestSurfaceTestTypes.PushSource(backend: .syntheticTest)
    let counter = FrameReleaseCounter()
    try await source.start { $0.release() }
    let first = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 8, height: 8, backend: .syntheticTest), onRelease: { counter.increment() })
    XCTAssertTrue(source.publish(first))
    let stale = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 1, width: 8, height: 8, backend: .syntheticTest), onRelease: { counter.increment() })
    XCTAssertFalse(source.publish(stale))
    let mismatched = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 2, width: 8, height: 8, backend: .unavailable), onRelease: { counter.increment() })
    XCTAssertFalse(source.publish(mismatched))
    await source.stop()
    let stopped = GuestSurfaceTestTypes.Frame(
      descriptor: GuestSurfaceTestTypes.FrameDescriptor(
        frameID: 3, width: 8, height: 8, backend: .syntheticTest), onRelease: { counter.increment() })
    XCTAssertFalse(source.publish(stopped))
    XCTAssertEqual(counter.count, 4)
  }

}

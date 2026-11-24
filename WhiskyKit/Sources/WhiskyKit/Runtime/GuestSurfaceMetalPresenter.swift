// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface
import Metal
import QuartzCore

public enum GuestSurfaceBindingError: Error, Equatable, Sendable {
  case missingSurface, invalidDimensions, surfaceIdentityMismatch, pixelFormatMismatch
  case incompleteSynchronization, deviceMismatch, metalUnavailable
}

/// Imports the producer's storage as a Metal texture without reading or copying its pixels.
public enum GuestSurfaceTextureBinding {
  public static func makeTexture(for frame: GuestSurfaceFrame, device: MTLDevice) throws -> MTLTexture {
    guard let surface = frame.surface else { throw GuestSurfaceBindingError.missingSurface }
    let descriptor = frame.descriptor
    guard descriptor.width > 0, descriptor.height > 0,
      descriptor.width <= 16384, descriptor.height <= 16384,
      IOSurfaceGetWidth(surface) == descriptor.width,
      IOSurfaceGetHeight(surface) == descriptor.height
    else {
      throw GuestSurfaceBindingError.invalidDimensions
    }
    guard descriptor.ioSurfaceID == IOSurfaceGetID(surface) else {
      throw GuestSurfaceBindingError.surfaceIdentityMismatch
    }
    guard IOSurfaceGetPlaneCount(surface) == 0,
      IOSurfaceGetPixelFormat(surface) == descriptor.pixelFormat.osType,
      IOSurfaceGetBytesPerElement(surface) == descriptor.pixelFormat.bytesPerElement,
      IOSurfaceGetBytesPerRow(surface) >= descriptor.width * descriptor.pixelFormat.bytesPerElement,
      IOSurfaceGetAllocSize(surface) >= IOSurfaceGetBytesPerRow(surface) * descriptor.height
    else {
      throw GuestSurfaceBindingError.pixelFormatMismatch
    }
    guard (frame.sharedEvent == nil) == (descriptor.sharedEventSignaledValue == nil) else {
      throw GuestSurfaceBindingError.incompleteSynchronization
    }
    if let eventDevice = frame.sharedEvent?.device, eventDevice.registryID != device.registryID {
      throw GuestSurfaceBindingError.deviceMismatch
    }
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: descriptor.pixelFormat == .bgra8Unorm ? .bgra8Unorm : .rgba16Float,
      width: descriptor.width, height: descriptor.height, mipmapped: false)
    textureDescriptor.usage = .shaderRead
    textureDescriptor.storageMode = .shared
    guard
      let texture = device.makeTexture(descriptor: textureDescriptor, iosurface: surface, plane: 0)
    else {
      throw GuestSurfaceBindingError.metalUnavailable
    }
    return texture
  }
}

/// No CPU pixel copy. Metal samples the imported IOSurface into a compositor-owned drawable.
/// The final GPU write is explicit; an arbitrary IOSurface cannot replace CAMetalDrawable storage.
public final class GuestSurfaceMetalPresenter: @unchecked Sendable {
  public let device: MTLDevice
  private let queue: MTLCommandQueue
  private let library: MTLLibrary
  private let pipelineLock = NSLock()
  private var pipelines: [UInt: MTLRenderPipelineState] = [:]

  public init(device: MTLDevice) throws {
    self.device = device
    guard let queue = device.makeCommandQueue() else {
      throw GuestSurfaceBindingError.metalUnavailable
    }
    self.queue = queue
    library = try device.makeLibrary(source: Self.shader, options: nil)
  }

  public func encode(_ frame: GuestSurfaceFrame, target: MTLTexture) throws -> MTLCommandBuffer {
    let source = try GuestSurfaceTextureBinding.makeTexture(for: frame, device: device)
    guard target.device.registryID == device.registryID,
      let command = queue.makeCommandBuffer()
    else { throw GuestSurfaceBindingError.deviceMismatch }
    let pipeline = try pipeline(for: target.pixelFormat)
    if let event = frame.sharedEvent, let value = frame.descriptor.sharedEventSignaledValue {
      command.encodeWaitForEvent(event, value: value)
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw GuestSurfaceBindingError.metalUnavailable
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(source, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    command.addCompletedHandler { _ in frame.release() }
    return command
  }

  private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
    pipelineLock.lock()
    defer { pipelineLock.unlock() }
    if let cached = pipelines[format.rawValue] { return cached }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "surfaceVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "surfaceFragment")
    descriptor.colorAttachments[0].pixelFormat = format
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    pipelines[format.rawValue] = pipeline
    return pipeline
  }

  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SurfaceVertex { float4 position [[position]]; float2 uv; };
    vertex SurfaceVertex surfaceVertex(uint id [[vertex_id]]) {
      float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
      SurfaceVertex result;
      result.position = float4(positions[id], 0, 1);
      result.uv = positions[id] * float2(0.5, -0.5) + 0.5;
      return result;
    }
    fragment float4 surfaceFragment(SurfaceVertex input [[stage_in]], texture2d<float> image [[texture(0)]]) {
      constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::nearest);
      return image.sample(sampling, input.uv);
    }
    """
}

extension GuestSurfaceFrame {
  public func waitForProducer(timeoutMilliseconds: Int = 1000) async -> Bool {
    guard !Task.isCancelled else { return false }
    guard let event = sharedEvent, let value = descriptor.sharedEventSignaledValue else {
      return sharedEvent == nil && descriptor.sharedEventSignaledValue == nil
    }
    let deadline = ContinuousClock.now + .milliseconds(max(1, min(5000, timeoutMilliseconds)))
    while event.signaledValue < value {
      guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
      do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
    }
    return true
  }
}

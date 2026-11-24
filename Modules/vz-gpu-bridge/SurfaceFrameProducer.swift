// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

@available(macOS 27.0, *)
private final class SurfacePoolSlot {
    let renderer: InProcessZeroCopyRenderer
    var leased = false

    init(width: Int, height: Int, draws: Int) throws {
        renderer = try InProcessZeroCopyRenderer(width: width, height: height, maxDraws: draws)
    }
}

@available(macOS 27.0, *)
// All mutable producer state is confined to its private serial queue.
public final class SurfaceFrameProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "demo-app.surface-producer")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var slots: [SurfacePoolSlot]
    private var timer: DispatchSourceTimer?
    private var callback: ((SurfaceFrameLease) -> Void)?
    private var running = false
    private var frameID: UInt64 = 0
    private var dropped: UInt64 = 0
    private var returned: UInt64 = 0
    private var failures: UInt64 = 0
    private var generation: UInt64 = 1
    private let draws: Int
    private var refreshRateMilliHz: Int

    public init(width: Int, height: Int, draws: Int = 2048, refreshRateMilliHz: Int = 120000) throws {
        guard (30000...240000).contains(refreshRateMilliHz) else {
            throw NSError(domain: "SurfaceProducer", code: 1)
        }
        self.draws = draws
        self.refreshRateMilliHz = refreshRateMilliHz
        slots = try (0..<3).map { _ in try SurfacePoolSlot(width: width, height: height, draws: draws) }
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start(onFrame: @escaping (SurfaceFrameLease) -> Void) {
        queue.async { [self] in
            guard !self.running else { return }
            self.callback = onFrame
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = 1_000_000_000_000 / self.refreshRateMilliHz
            timer.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.produceFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.callback = nil
            completion()
        }
    }

    public func resize(width: Int, height: Int, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            do {
                let slots = try (0..<3).map { _ in
                    try SurfacePoolSlot(width: width, height: height, draws: self.draws)
                }
                self.slots = slots
                self.generation &+= 1
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    public func snapshot() -> [String: UInt64] {
        let read = {
            ["produced": self.frameID, "dropped": self.dropped, "released": self.returned,
             "failures": self.failures, "generation": self.generation,
             "leased": UInt64(self.slots.filter { $0.leased }.count), "pool_size": UInt64(self.slots.count)]
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { return read() }
        return queue.sync(execute: read)
    }

    private func produceFrame() {
        guard running else { return }
        guard let slot = slots.first(where: { !$0.leased }) else {
            dropped &+= 1
            return
        }
        do {
            try slot.renderer.renderFrame(drawCalls: draws, frameIndex: UInt32(truncatingIfNeeded: frameID),
                                          readbackToBuffer: nil)
            frameID &+= 1
            slot.leased = true
            let bridge = slot.renderer.presentBridge
            let descriptor = bridge.descriptor
            let metadata = SurfaceFrameMetadata(frameID: frameID, generation: generation,
                width: descriptor.width, height: descriptor.height, bytesPerRow: descriptor.bytesPerRow,
                readyValue: bridge.signalValue, refreshRateMilliHz: refreshRateMilliHz)
            let frame = SurfaceFrameLease(metadata: metadata, surface: bridge.surface,
                                          readyEvent: bridge.sharedEvent) { [weak self, slot] in
                self?.queue.async {
                    slot.leased = false
                    self?.returned &+= 1
                }
            }
            callback?(frame)
        } catch {
            failures &+= 1
            running = false
            timer?.cancel()
        }
    }
}

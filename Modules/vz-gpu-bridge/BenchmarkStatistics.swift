// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Darwin
import Foundation

@available(macOS 26.0, *)
extension InProcessZeroCopyRenderer {
    public struct BenchmarkSampleInput {
        public let mode: String
        public let width: Int
        public let height: Int
        public let drawCalls: Int
        public let warmupFrames: Int
        public let latenciesMs: [Double]
        public let wallMs: Double
        public let cpuUserMs: Double
        public let cpuSysMs: Double
        public let zeroCopySurfaceActive: Bool
        public let firstPixel: [UInt8]
    }

    public static func processCpuTimesMs() -> (userMs: Double, sysMs: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000,
                Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000)
    }

    public static func percentile(_ sorted: [Double], ratio: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * ratio)))
        return sorted[index]
    }

    public static func makeSample(_ input: BenchmarkSampleInput) -> BenchmarkSample {
        let sorted = input.latenciesMs.sorted()
        let count = max(1, sorted.count)
        var sample = BenchmarkSample(mode: input.mode, width: input.width, height: input.height,
            drawCalls: input.drawCalls, frames: sorted.count, warmupFrames: input.warmupFrames,
            meanMs: sorted.reduce(0, +) / Double(count), p50Ms: percentile(sorted, ratio: 0.50),
            p95Ms: percentile(sorted, ratio: 0.95), p99Ms: percentile(sorted, ratio: 0.99),
            fps: input.wallMs > 0 ? Double(sorted.count) * 1000 / input.wallMs : 0,
            wallMs: input.wallMs, cpuUserMs: input.cpuUserMs, cpuSysMs: input.cpuSysMs,
            hostCpuPercent: input.wallMs > 0 ? (input.cpuUserMs + input.cpuSysMs) / input.wallMs * 100 : 0,
            zeroCopySurfaceActive: input.zeroCopySurfaceActive, firstPixelBGRA: input.firstPixel)
        sample.frameLatenciesMs = input.latenciesMs
        return sample
    }
}

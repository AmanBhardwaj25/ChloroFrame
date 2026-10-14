//
//  PyroWaveDecodeBenchmark.swift
//  ChloroFrame
//
//  Readiness check C15 (design/pyrowave-implementation-plan.md D5b and D6): how long does this
//  Mac's GPU take to decode a PyroWave frame at the stream size? One synthetic frame is encoded
//  once with the vendored encoder, then decoded 5 times to warm up and 30 times for the
//  measurement. Result is the average GPU execution time (`gpuEndTime - gpuStartTime`) in
//  milliseconds, the same quantity the G1 gate used.
//
//  Decode time is nearly independent of content and payload size (D3 measured a dense noise
//  frame at 0.34 ms against 0.15 ms for a smooth one at 1080p), so a synthetic frame at the
//  default bitrate for the size is representative.
//
//  Results are cached for the app session per (width, height, chroma, bitDepth).
//

import Foundation
import CoreMedia
import Metal
import QuartzCore

nonisolated enum PyroWaveDecodeBenchmark {

    static let warmUpFrames = 5
    static let timedFrames = 30

    struct Measurement: Equatable, Sendable {
        /// Average GPU execution time per decode, milliseconds.
        var averageGPUMs: Double
        /// Slowest timed decode, milliseconds.
        var maxGPUMs: Double
        /// Whole benchmark including the shared device (when not yet created) and the encode.
        var wallMs: Double
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(String)
        case timedOut(decode: Int)

        var description: String {
            switch self {
            case .unsupportedFormat(let why): return "benchmark unsupported: \(why)"
            case .timedOut(let n): return "benchmark decode \(n) did not complete"
            }
        }
    }

    /// Average GPU decode milliseconds for `format` on `device`. Runs on a background queue.
    /// Throws when the format cannot be benchmarked or the decode fails; callers treat that as
    /// "unknown" (never as a slow result).
    static func run(device: MTLDevice, format: PyroWaveStreamFormat) async throws -> Double {
        try await measure(device: device, format: format).averageGPUMs
    }

    /// Same as `run` with the extra numbers, for logging.
    static func measure(device: MTLDevice, format: PyroWaveStreamFormat) async throws -> Measurement {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try measureSync(device: device, format: format))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous core

    static func measureSync(device: MTLDevice, format: PyroWaveStreamFormat) throws -> Measurement {
        // The vendored encoder wrapper takes 8-bit planes only; 10-bit arrives with D9.
        guard format.bitDepth == 8 else { throw Failure.unsupportedFormat("bit depth \(format.bitDepth)") }
        guard format.width >= 64, format.height >= 64 else {
            throw Failure.unsupportedFormat("size \(format.width)x\(format.height)")
        }
        let start = CACurrentMediaTime()

        let shared = try PyroWaveDevice.shared(for: device)
        let encoder = try PyroWaveEncoder(device: shared, width: format.width, height: format.height,
                                          chroma444: format.chroma444)
        let image = syntheticImage(width: format.width, height: format.height, chroma444: format.chroma444)
        // Budget for one frame at the default bitrate for this size at 60 fps.
        let kbps = PyroWaveBitrate.defaultKbps(width: format.width, height: format.height, fps: 60,
                                               yuv444: format.chroma444)
        let budget = kbps * 1000 / 8 / 60
        let packets = try encoder.encode(y: image.y, cb: image.cb, cr: image.cr, maximumBitstreamSize: budget)
        var frame = Data()
        for packet in packets { frame.append(packet) }

        let decoder = try PyroWaveDecoder(device: device, format: format)
        let lock = NSLock()
        var gpuTimes: [Double] = []
        let done = DispatchSemaphore(value: 0)
        decoder.onGPUTime = { ms in lock.withLock { gpuTimes.append(ms) } }
        decoder.onFrameDecoded = { _, _ in done.signal() }

        for i in 0..<(warmUpFrames + timedFrames) {
            decoder.submit(frame: frame, pts: .zero)
            // One decode at a time so the mailbox never replaces a frame and each timing is clean.
            guard done.wait(timeout: .now() + 2) == .success else { throw Failure.timedOut(decode: i) }
        }
        decoder.onFrameDecoded = nil
        decoder.onGPUTime = nil

        let timed = lock.withLock { Array(gpuTimes.dropFirst(warmUpFrames)) }
        guard !timed.isEmpty else { throw Failure.timedOut(decode: gpuTimes.count) }
        return Measurement(averageGPUMs: timed.reduce(0, +) / Double(timed.count),
                           maxGPUMs: timed.max() ?? 0,
                           wallMs: (CACurrentMediaTime() - start) * 1000)
    }

    /// Luma gradient with a checkerboard block and a pseudo-random patch, plus smooth chroma.
    /// Deterministic, so repeated runs compare.
    static func syntheticImage(width: Int, height: Int, chroma444: Bool) -> (y: [UInt8], cb: [UInt8], cr: [UInt8]) {
        var y = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                var v = (col * 160) / width + (row * 80) / height + 16
                if col >= width / 8, col < width * 3 / 8, row >= height / 8, row < height * 3 / 8 {
                    v = ((col / 16) + (row / 16)) & 1 == 0 ? 215 : 40
                }
                y[row * width + col] = UInt8(min(v, 255))
            }
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let px = width * 5 / 8, py = height * 5 / 8
        for row in py..<min(py + 64, height) {
            for col in px..<min(px + 64, width) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                y[row * width + col] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        let cw = chroma444 ? width : width / 2
        let ch = chroma444 ? height : height / 2
        var cb = [UInt8](repeating: 0, count: cw * ch)
        var cr = [UInt8](repeating: 0, count: cw * ch)
        for row in 0..<ch {
            for col in 0..<cw {
                cb[row * cw + col] = UInt8(64 + (col * 128) / cw)
                cr[row * cw + col] = UInt8(64 + (row * 128) / ch)
            }
        }
        return (y, cb, cr)
    }
}

// MARK: - Session cache

nonisolated enum PyroWaveBenchmarkCache {
    private struct Key: Hashable {
        let width: Int, height: Int, chroma444: Bool, bitDepth: Int
        init(_ f: PyroWaveStreamFormat) {
            width = f.width; height = f.height; chroma444 = f.chroma444; bitDepth = f.bitDepth
        }
    }

    private static let lock = NSLock()
    private static var results: [Key: Double] = [:]

    static func averageGPUMs(for format: PyroWaveStreamFormat) -> Double? {
        lock.withLock { results[Key(format)] }
    }

    static func store(_ ms: Double, for format: PyroWaveStreamFormat) {
        lock.withLock { results[Key(format)] = ms }
    }

    static func removeAll() { lock.withLock { results.removeAll() } }
}

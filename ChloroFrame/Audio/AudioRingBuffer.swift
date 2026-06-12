//
//  AudioRingBuffer.swift
//  ChloroFrame
//
//  SPSC lock-free ring buffer for interleaved stereo float32 PCM.
//  Writer: AudioEngine.audioQueue (sole producer).
//  Reader: CoreAudio render callback (sole consumer).
//
//  Positions are monotonically increasing Int — never wrap on 64-bit.
//  Use `pos & mask` to index into the buffer array.
//  Acquire/release ordering on the position atomics establishes the
//  happens-before relationship between data writes and data reads.

import Foundation
import Synchronization
import AudioToolbox

final class AudioRingBuffer: @unchecked Sendable {

    private let capacity: Int                          // power of 2, in frames
    private let mask:     Int                          // capacity - 1
    private let buf:      UnsafeMutablePointer<Float>  // capacity * 2 interleaved floats

    // Sole writer of writePos: audioQueue.
    // Sole writer of readPos:  CoreAudio render callback.
    private let writePos = Atomic<Int>(0)
    private let readPos  = Atomic<Int>(0)

    // Written only by the render callback (single writer) — Atomic for cross-thread visibility.
    private let _underruns = Atomic<Int>(0)
    // Written only by the audioQueue writer — Atomic for cross-thread visibility.
    private let _overruns  = Atomic<Int>(0)

    var underrunCount: Int { _underruns.load(ordering: .relaxed) }
    var overrunCount:  Int { _overruns.load(ordering: .relaxed) }

    /// Available frames readable by the consumer.
    var availableFrames: Int {
        writePos.load(ordering: .acquiring) - readPos.load(ordering: .acquiring)
    }

    init(capacityFrames: Int = 8192) {
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0,
                     "capacityFrames must be a power of 2")
        capacity = capacityFrames
        mask     = capacityFrames - 1
        buf      = .allocate(capacity: capacityFrames * 2)
        buf.initialize(repeating: 0.0, count: capacityFrames * 2)
    }

    deinit { buf.deallocate() }

    // MARK: - Write (audioQueue only)

    /// Write `frameCount` interleaved stereo frames from `src`.
    /// Returns the number of frames actually written (drops if full).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, frameCount: Int) -> Int {
        let wp    = writePos.load(ordering: .relaxed)
        let rp    = readPos.load(ordering: .acquiring)
        let free  = capacity - (wp - rp)
        let count = min(frameCount, free)
        if count < frameCount {
            _overruns.store(_overruns.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
        }
        for i in 0..<count {
            let idx = (wp + i) & mask
            buf[idx * 2]     = src[i * 2]
            buf[idx * 2 + 1] = src[i * 2 + 1]
        }
        writePos.store(wp + count, ordering: .releasing)
        return count
    }

    // MARK: - Read (CoreAudio render callback only)

    /// Read `frameCount` frames into a non-interleaved stereo AudioBufferList (2 channels).
    /// Zero-fills any frames beyond available. Returns frames read from the buffer.
    @discardableResult
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Int {
        let rp    = readPos.load(ordering: .relaxed)
        let wp    = writePos.load(ordering: .acquiring)
        let avail = wp - rp
        let count = min(frameCount, avail)

        let ablBufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = ablBufs[0].mData!.assumingMemoryBound(to: Float.self)
        let R = ablBufs[1].mData!.assumingMemoryBound(to: Float.self)

        for i in 0..<count {
            let idx = (rp + i) & mask
            L[i] = buf[idx * 2]
            R[i] = buf[idx * 2 + 1]
        }
        if count < frameCount {
            let silence = frameCount - count
            memset(L + count, 0, silence * MemoryLayout<Float>.size)
            memset(R + count, 0, silence * MemoryLayout<Float>.size)
            // Non-atomic RMW is safe — render callback is the sole writer of _underruns.
            _underruns.store(_underruns.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
        }

        readPos.store(rp + count, ordering: .releasing)
        return count
    }

    // MARK: - Reset (call only when stopped — not thread-safe during operation)

    func reset() {
        writePos.store(0, ordering: .relaxed)
        readPos.store(0, ordering: .relaxed)
        buf.initialize(repeating: 0.0, count: capacity * 2)
        _underruns.store(0, ordering: .relaxed)
        _overruns.store(0, ordering: .relaxed)
    }
}

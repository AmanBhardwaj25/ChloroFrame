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
import CoreAudio   // UnsafeMutableAudioBufferListPointer (no longer re-exported by AudioToolbox on current SDKs)

final class AudioRingBuffer: @unchecked Sendable {

    private let capacity: Int                          // power of 2, in frames
    private let mask:     Int                          // capacity - 1
    private let buf:      UnsafeMutablePointer<Float>  // capacity * 2 interleaved floats

    // Frames the ring must accumulate before the (pre-warmed) render callback starts
    // consuming. Until then read() outputs silence without advancing readPos.
    private let primingTargetFrames: Int

    // Upper bound on playback latency, below the physical ring size. If more than this is
    // buffered (a delivery burst), read() skips the oldest down to the cap. This catches
    // bursts immediately, before the slow drift servo would. The physical ring stays
    // `capacity` (170 ms) so the writer keeps slack between reads; this only bounds how much
    // of it we play behind live. Mutable (Atomic) so the adaptive jitter buffer can move the
    // ceiling as its target grows/shrinks; written by audioQueue, read by the render callback.
    private let _maxLatencyFrames: Atomic<Int>

    // Sole writer of writePos: audioQueue.
    // Sole writer of readPos:  CoreAudio render callback.
    private let writePos = Atomic<Int>(0)
    private let readPos  = Atomic<Int>(0)

    // Written only by the render callback (single writer) — Atomic for cross-thread visibility.
    private let _underruns = Atomic<Int>(0)
    // Written only by the audioQueue writer — Atomic for cross-thread visibility.
    private let _overruns  = Atomic<Int>(0)

    // Monotonic time (CLOCK_MONOTONIC_RAW ns) of the first read() that returned data.
    // Written once by the render callback; 0 until then. Diagnostic for startup over-fill.
    private let _firstReadNanos = Atomic<UInt64>(0)

    // Frames discarded by the one-time snap-to-target when priming completes. 0 means the
    // pre-warm fully hid the engine cold start; larger means audio arrived before the engine
    // warmed and the snap shed the excess so playback still begins at the target latency.
    private let _primeDropFrames = Atomic<Int>(0)

    // Cumulative frames the max-latency clamp skipped (oldest audio dropped to bound latency
    // when a burst pushed occupancy past maxLatencyFrames). Sole writer: the render callback.
    private let _latencyClampFrames = Atomic<Int>(0)

    // Latency the drift servo (audioQueue) asks the reader to shed. The render callback drains
    // it on its next pull and applies it as a crossfaded skip — same click-free path as the
    // latency clamp — instead of the writer hard-dropping a whole packet.
    private let _pendingShedFrames = Atomic<Int>(0)

    // Equal-power crossfade window applied at any reader-side skip (clamp or drift shed) so the
    // splice is click-free instead of a hard jump. ~1.3 ms at 48 kHz.
    private static let skipCrossfadeFrames: Int = 64

    var underrunCount:  Int    { _underruns.load(ordering: .relaxed) }
    var overrunCount:   Int    { _overruns.load(ordering: .relaxed) }
    var firstReadNanos: UInt64 { _firstReadNanos.load(ordering: .relaxed) }
    var primeDropFrames: Int   { _primeDropFrames.load(ordering: .relaxed) }
    var latencyClampFrames: Int { _latencyClampFrames.load(ordering: .relaxed) }

    // Underrun concealment (render callback only — single thread, no atomics needed).
    // On starvation we repeat the most recent real audio across the gap, indexed as a triangle
    // (backward then forward over the window) so the seam is value-continuous — no click — and
    // the gap is filled with content of the same texture/energy rather than a silence dip. A
    // long gap decays to silence to avoid a buzzing loop; real audio is ramped back in on
    // recovery. Far better than fade-to-silence for sustained content (speech, noise).
    private static let concealLoopLen:    Int = 960    // 20 ms repeat window
    private static let concealHoldFrames: Int = 1440   // 30 ms full-level repeat before fading
    private static let concealFadeFrames: Int = 1440   // then 30 ms fade to silence
    private static let recoverLen:        Int = 240    // 5 ms fade-in on recovery
    private var concealActive:    Bool = false
    private var concealPos:       Int  = 0             // frames emitted in the current gap
    private var concealLoopStart: Int  = 0             // absolute pos where the repeat window begins
    private var recoverPos:       Int  = 240           // < recoverLen ⇒ ramping real audio back in

    /// Available frames readable by the consumer.
    /// Clamped to `capacity`: under the skip-ahead overrun policy the writer can run
    /// ahead of an un-clamped reader transiently, so the raw delta may briefly exceed
    /// the ring size before the next read() snaps readPos forward.
    var availableFrames: Int {
        min(writePos.load(ordering: .acquiring) - readPos.load(ordering: .acquiring), capacity)
    }

    init(capacityFrames: Int = 8192, primingTargetFrames: Int, maxLatencyFrames: Int) {
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0,
                     "capacityFrames must be a power of 2")
        precondition(primingTargetFrames > 0 && primingTargetFrames <= maxLatencyFrames,
                     "primingTargetFrames must be in 1...maxLatencyFrames")
        precondition(maxLatencyFrames <= capacityFrames,
                     "maxLatencyFrames must be <= capacityFrames")
        capacity = capacityFrames
        mask     = capacityFrames - 1
        self.primingTargetFrames = primingTargetFrames
        self._maxLatencyFrames   = Atomic<Int>(maxLatencyFrames)
        buf      = .allocate(capacity: capacityFrames * 2)
        buf.initialize(repeating: 0.0, count: capacityFrames * 2)
    }

    /// Move the latency ceiling (adaptive jitter buffer). Clamped to the physical ring.
    /// Called on audioQueue; the render callback reads it on its next pull.
    func setMaxLatencyFrames(_ n: Int) {
        _maxLatencyFrames.store(min(max(n, primingTargetFrames), capacity), ordering: .relaxed)
    }

    /// Drift servo (audioQueue): ask the reader to shed `frames` of latency with a crossfade,
    /// instead of the writer hard-dropping a packet. Accumulates until the next read().
    func requestShed(frames: Int) {
        guard frames > 0 else { return }
        _pendingShedFrames.store(_pendingShedFrames.load(ordering: .relaxed) &+ frames, ordering: .relaxed)
    }

    deinit { buf.deallocate() }

    // MARK: - Write (audioQueue only)

    /// Write `frameCount` interleaved stereo frames from `src`.
    ///
    /// Skip-ahead overrun policy: the freshest audio is never dropped. When the ring is
    /// full we overwrite the OLDEST unread frames; the reader detects the lap in read()
    /// and advances readPos past the overwritten span. The previous policy dropped the
    /// NEWEST samples (wrote only what fit), which pinned latency at the ring maximum and
    /// discarded just-arrived audio in partial-packet chunks — audibly worse than a clean
    /// skip of stale audio. The real cure for steady-state drift is the playback servo;
    /// this just makes the failure mode benign in the meantime.
    ///
    /// Returns the number of frames written (== `frameCount`, clamped to `capacity`).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, frameCount: Int, fadeInFrames: Int = 0) -> Int {
        let wp = writePos.load(ordering: .relaxed)
        let rp = readPos.load(ordering: .acquiring)

        // Opus packets are at most 960 frames vs an 8192-frame ring, so a single write
        // never laps itself; clamp defensively so an oversized write keeps only its tail.
        let count = min(frameCount, capacity)
        let srcOffset = frameCount - count   // skip leading frames if over capacity

        if frameCount > capacity - (wp - rp) {
            _overruns.store(_overruns.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
        }

        // Optional fade-in from the last published sample. Used to splice a duplicated packet
        // (drift insert) onto the stream without a click. Reads buf[wp-1] (a concurrent read
        // with the consumer is not a data race) and writes only the unpublished [wp, wp+count).
        let fade = min(max(fadeInFrames, 0), count)
        var lastL: Float = 0, lastR: Float = 0
        if fade > 0, wp > 0 {
            let lidx = (wp - 1) & mask
            lastL = buf[lidx * 2]
            lastR = buf[lidx * 2 + 1]
        }

        for i in 0..<count {
            let idx = (wp + i) & mask
            var l = src[(srcOffset + i) * 2]
            var r = src[(srcOffset + i) * 2 + 1]
            if i < fade {
                let g = Float(i + 1) / Float(fade + 1)   // 0 → 1
                l = lastL * (1 - g) + l * g
                r = lastR * (1 - g) + r * g
            }
            buf[idx * 2]     = l
            buf[idx * 2 + 1] = r
        }
        writePos.store(wp + count, ordering: .releasing)
        return count
    }

    // MARK: - Read (CoreAudio render callback only)

    /// Read `frameCount` frames into a non-interleaved stereo AudioBufferList (2 channels).
    /// Zero-fills any frames beyond available. Returns frames read from the buffer.
    @discardableResult
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Int {
        let ablBufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = ablBufs[0].mData!.assumingMemoryBound(to: Float.self)
        let R = ablBufs[1].mData!.assumingMemoryBound(to: Float.self)

        var rp    = readPos.load(ordering: .relaxed)
        let wp    = writePos.load(ordering: .acquiring)

        // Priming gate (pre-warm). `rp == 0` means we have never consumed yet. Until the
        // ring first reaches the priming target, output pure silence WITHOUT advancing
        // readPos so the cushion can build while the engine is already warm and calling in.
        if rp == 0 {
            if wp - rp < primingTargetFrames {
                memset(L, 0, frameCount * MemoryLayout<Float>.size)
                memset(R, 0, frameCount * MemoryLayout<Float>.size)
                return 0
            }
            // Priming complete: snap to exactly primingTargetFrames so playback begins at the
            // target latency no matter how much piled up while the engine was cold-starting.
            // Safe: this callback is the sole writer of readPos. Record the drop for stats.
            let excess = (wp - rp) - primingTargetFrames
            if excess > 0 {
                rp = wp - primingTargetFrames
                _primeDropFrames.store(excess, ordering: .relaxed)
            }
        }

        // Reader-side skip = latency clamp + drift-servo shed, applied as ONE crossfaded jump.
        //  - Latency clamp bounds playback latency at maxLatencyFrames (a delivery burst gets its
        //    oldest audio skipped, rather than waiting for the slow drift servo).
        //  - Drift shed is what the servo requests instead of the writer hard-dropping a packet.
        // readPos stays single-writer (this callback), so advancing it here is race-free; the
        // crossfade below makes the splice click-free instead of a hard jump.
        let entryRp = rp
        var skip = 0
        let maxLat = _maxLatencyFrames.load(ordering: .relaxed)
        if wp - rp > maxLat {
            let clampSkip = (wp - rp) - maxLat
            _latencyClampFrames.store(_latencyClampFrames.load(ordering: .relaxed) &+ clampSkip, ordering: .relaxed)
            skip += clampSkip
        }
        let shedReq = _pendingShedFrames.exchange(0, ordering: .relaxed)
        if shedReq > 0 {
            // Never shed so far that we starve this pull of its `frameCount` frames.
            let room = max(0, (wp - rp) - skip - frameCount)
            skip += min(shedReq, room)
        }
        rp += skip

        let avail = wp - rp
        let count = min(frameCount, avail)

        // Stamp the first time we actually deliver audio (diagnostic for startup over-fill).
        // clock_gettime_nsec_np is a vDSO read: no syscall, lock, or allocation, so it is
        // safe in the real-time render callback. Sole writer is this callback.
        if count > 0, _firstReadNanos.load(ordering: .relaxed) == 0 {
            _firstReadNanos.store(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), ordering: .relaxed)
        }

        // Recovery: if we were concealing and real audio is back, ramp it in over ~5 ms so the
        // transition out of the repeated waveform doesn't click.
        if concealActive && count > 0 {
            concealActive = false
            recoverPos = 0
        }

        // When we skipped, equal-power crossfade the first `xfade` output frames from the stale
        // continuation (entryRp+i, continuous with the previous pull) into the kept stream (rp+i).
        let xfade = skip > 0 ? min(Self.skipCrossfadeFrames, count) : 0
        for i in 0..<count {
            let idx = (rp + i) & mask
            var l = buf[idx * 2]
            var r = buf[idx * 2 + 1]
            if i < xfade {
                let theta  = (Float(i) + 0.5) / Float(xfade) * (Float.pi / 2)   // 0 → π/2
                let gKept  = sin(theta)
                let gStale = cos(theta)
                let sidx = (entryRp + i) & mask
                l = buf[sidx * 2]     * gStale + l * gKept
                r = buf[sidx * 2 + 1] * gStale + r * gKept
            }
            if recoverPos < Self.recoverLen {
                let g = Float(recoverPos) / Float(Self.recoverLen)
                l *= g
                r *= g
                recoverPos += 1
            }
            L[i] = l
            R[i] = r
        }
        if count < frameCount {
            // Underrun: fill the shortfall by repeating the last 20 ms of real audio, indexed
            // as a triangle (backward then forward) so frame 0 == the last real sample (seam is
            // value-continuous), decaying to silence if the gap runs long.
            if !concealActive {
                concealActive = true
                concealPos = 0
                concealLoopStart = wp - Self.concealLoopLen   // wp ≥ primingTarget ⇒ ≥ 0
            }
            let win    = Self.concealLoopLen
            let period = 2 * (win - 1)                         // back-and-forth, endpoints not doubled
            for i in count..<frameCount {
                let j = concealPos
                let gain: Float
                if j < Self.concealHoldFrames {
                    gain = 1.0
                } else if j < Self.concealHoldFrames + Self.concealFadeFrames {
                    gain = 1.0 - Float(j - Self.concealHoldFrames) / Float(Self.concealFadeFrames)
                } else {
                    gain = 0.0
                }
                if gain > 0.0 {
                    let pos  = j % period
                    let widx = pos < win ? (win - 1 - pos) : (pos - win + 1)
                    let s    = (concealLoopStart + widx) & mask
                    L[i] = buf[s * 2]     * gain
                    R[i] = buf[s * 2 + 1] * gain
                } else {
                    L[i] = 0
                    R[i] = 0
                }
                concealPos += 1
            }
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
        _firstReadNanos.store(0, ordering: .relaxed)
        _primeDropFrames.store(0, ordering: .relaxed)
        _latencyClampFrames.store(0, ordering: .relaxed)
        _pendingShedFrames.store(0, ordering: .relaxed)
        concealActive = false
        concealPos = 0
        concealLoopStart = 0
        recoverPos = Self.recoverLen
    }
}

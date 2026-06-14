//
//  AudioEngine.swift
//  ChloroFrame
//
//  Audio orchestrator: receives NetworkAudioPacket from RTPAudioReceiver,
//  decodes Opus via libopus on audioQueue, writes interleaved PCM into the ring
//  buffer, and drives a CoreAudio pull model via AVAudioSourceNode.
//
//  Threading model:
//    audioQueue  — sole writer to ring buffer; runs all decode and state transitions
//    CoreAudio   — sole reader from ring buffer; render callback must not alloc/lock/decode
//
//  State machine:
//    stopped  → (start called) → priming
//    priming  → (ring buffer reaches targetPrimingFrames) → running
//    running  → (stop called) → stopped
//
//  Codec:
//    libopus opus_decode_float() — correctly decodes any Opus frame size (2.5/5/10/20ms)
//    in a single call, returning the exact PCM frame count. Apple's kAudioFormatOpus
//    AudioConverter is NOT used — it silently truncates 5ms CELT packets to 2.5ms (120
//    samples), causing 50% audio starvation and the characteristic robotic/choppy artefact.

import Foundation
import AVFoundation
import os

private let alog = Logger(subsystem: "com.chloroframe", category: "audio")

enum AudioEngineState {
    case stopped, priming, running

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .priming: return "priming"
        case .running: return "running"
        }
    }
}

enum AudioEngineError: Error {
    case decoderCreationFailed(Int32)
}

struct AudioEngineStats {
    let state:        AudioEngineState
    let bufferedMs:   Double
    let underrunCount: Int
    let overrunCount: Int
    let decodeCount:  Int
    let driftDrops:   Int    // packets skipped by the drift servo (buffer too full)
    let driftInserts: Int    // packets duplicated by the drift servo (buffer too empty)
    let latencyClampMs: Double  // cumulative ms of oldest audio skipped by the max-latency clamp
    let targetMs:     Double    // current adaptive-jitter-buffer target latency
}

final class AudioEngine: @unchecked Sendable {

    private static let sampleRate:          Double = 48000
    // Max frame size passed to opus_decode_float (20 ms at 48 kHz).
    // The actual frame count decoded is what libopus returns, not this ceiling.
    private static let maxFramesPerPacket:  Int    = 960
    // 60 ms buffered before the (pre-warmed) engine starts consuming, and the initial
    // adaptive-buffer target. Raised from 40 ms because 40 ran too tight in this CoreAudio
    // setup (playback began nearly drained on the first pull).
    private static let targetPrimingFrames: Int    = 2880

    // ── Adaptive jitter buffer ───────────────────────────────────────────────
    // The target occupancy is not fixed: it grows when underruns occur (the link is jittery
    // and we need more cushion to bridge gaps) and decays slowly when calm (reclaim latency).
    // The drift servo holds occupancy near this moving target; the ring's latency clamp tracks
    // a fixed margin above it. Grow-fast / decay-slow, mirroring the video buffer policy.
    private static let targetFloorFrames:  Int    = 2400   // 50 ms  — min latency when calm
    private static let targetCeilFrames:   Int    = 4560   // 95 ms  — max cushion under jitter
    private static let clampMarginFrames:  Int    = 1440   // 30 ms  — clamp ceiling above target
    // → max playback latency = ceil + margin = 125 ms. Worst-case lip-sync offset ≈ 125 − ~40
    //   (video age) = ~85 ms audio-behind, still under the ITU-R BT.1359 ~125 ms lag detection
    //   threshold and G.114's 150 ms "transparent" limit. The extra headroom over the old 100 ms
    //   cap lets the buffer absorb more jitter (fewer underruns); residual gaps are concealed by
    //   the waveform-repeat in AudioRingBuffer. Big stalls remain an AWDL problem.
    private static let adaptGrowFrames:    Int    = 480    // +10 ms per underrun episode
    private static let adaptGrowMinIntervalNanos: UInt64 = 250_000_000     // ≤1 growth / 250 ms
    private static let adaptDecayFrames:   Int    = 48     // -1 ms per decay tick
    private static let adaptDecayIntervalNanos:   UInt64 = 1_000_000_000   // decay 1 ms/s (slow reclaim)
    private static let adaptDecayQuietNanos:      UInt64 = 12_000_000_000  // hold ≥12 s after an underrun
    // Initial clamp ceiling = initial target + margin (60 + 30 = 90 ms).
    private static let initialMaxLatencyFrames: Int = targetPrimingFrames + clampMarginFrames

    // ── Drift servo ──────────────────────────────────────────────────────────
    // Host (48 kHz capture) and Mac output device clocks free-run, so ring
    // occupancy drifts monotonically without correction (the audible failure:
    // latency creep, eventual over/underrun, and A/V desync that wanders over a
    // session). We hold occupancy near targetPrimingFrames using packet-level
    // drop/duplicate corrections applied on the writer side only — readPos stays
    // owned by the render callback, so the SPSC contract is preserved.
    private static let driftBandFrames:      Int    = 480              // ±10 ms deadband
    private static let driftMinIntervalNanos: UInt64 = 2_000_000_000   // ≥2 s between corrections
    // Slow EMA (~5 s at 200 pkt/s) so the controller tracks true clock drift, not
    // per-packet network jitter. Each correction additionally biases the average by
    // the corrected frame count, so it integrates rather than re-firing every 2 s
    // while the slow average catches up.
    private static let driftAvgAlpha:        Double = 0.001            // EMA weight on occupancy

    private let ringBuffer = AudioRingBuffer(capacityFrames: 8192,                  // ~170 ms
                                             primingTargetFrames: targetPrimingFrames,
                                             maxLatencyFrames: initialMaxLatencyFrames)
    private let avEngine   = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var opusDecoder: OpaquePointer? = nil

    // audioQueue owns all mutable state below.
    private let audioQueue = DispatchQueue(label: "chloroframe.audio", qos: .userInteractive)
    private var state:       AudioEngineState = .stopped
    private var decodeCount: Int = 0

    // Drift servo state (audioQueue only).
    private var driftAvgFrames:     Double = Double(targetPrimingFrames)
    private var driftLastCorrection: UInt64 = 0
    private var driftDrops:         Int = 0
    private var driftInserts:       Int = 0

    // Adaptive jitter buffer state (audioQueue only).
    private var adaptiveTargetFrames: Double = Double(targetPrimingFrames)  // starts at 60 ms
    private var lastUnderrunCount:    Int    = 0
    private var lastUnderrunNanos:    UInt64 = 0
    private var lastAdaptGrowNanos:   UInt64 = 0
    private var lastAdaptDecayNanos:  UInt64 = 0

    // Diagnostics — track previous packet for delta logging (first 20 packets).
    private var diagPrevRtp:     UInt32? = nil
    private var diagPrevArrival: UInt64? = nil

    // Startup-timing diagnostics. The engine is pre-warmed (started at setup), so its
    // ~300 ms cold start burns off before audio matters; the render callback's snap-to-
    // target then guarantees playback begins at the priming target regardless of any
    // residual pile-up. We log how much the snap had to drop to confirm it worked.
    // audioQueue only.
    private var enginePrewarmNanos: UInt64 = 0

    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    // MARK: - Stats

    var stats: AudioEngineStats {
        audioQueue.sync {
            AudioEngineStats(
                state:         state,
                bufferedMs:    Double(ringBuffer.availableFrames) / Self.sampleRate * 1000,
                underrunCount: ringBuffer.underrunCount,
                overrunCount:  ringBuffer.overrunCount,
                decodeCount:   decodeCount,
                driftDrops:    driftDrops,
                driftInserts:  driftInserts,
                latencyClampMs: Double(ringBuffer.latencyClampFrames) / Self.sampleRate * 1000,
                targetMs:      adaptiveTargetFrames / Self.sampleRate * 1000
            )
        }
    }

    // MARK: - Lifecycle

    /// Synchronous: state is .priming before this returns, so no packets are dropped
    /// if the RTP receiver starts immediately after. Throws if the Opus decoder fails to
    /// initialize. Caller must NOT be on audioQueue (deadlock).
    func start() throws {
        try audioQueue.sync { [weak self] in try self?.startOnQueue() }
    }

    /// Safe to call from any thread EXCEPT audioQueue itself (deadlock).
    func stop() {
        audioQueue.sync { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - Packet ingestion (called from NW queue → dispatched to audioQueue)

    func push(packet: NetworkAudioPacket) {
        audioQueue.async { [weak self] in
            guard let self, self.state != .stopped else { return }
            self.decodeAndWrite(packet: packet)
        }
    }

    // MARK: - Private — audioQueue only

    private func startOnQueue() throws {
        guard state == .stopped else { return }
        var err: Int32 = 0
        opusDecoder = opus_decoder_create(48000, 2, &err)
        guard err == OPUS_OK, opusDecoder != nil else {
            throw AudioEngineError.decoderCreationFailed(err)
        }
        setupSourceNode()
        state = .priming
        // Pre-warm: start the engine NOW, during connection setup, so its ~300 ms cold
        // start happens before audio is flowing. The render callback outputs silence
        // (without consuming) until the ring primes; see AudioRingBuffer.read. Previously
        // we started the engine only after buffering 40 ms, so the cold start piled
        // real-time audio into the ring and playback began ~120 ms behind video.
        enginePrewarmNanos = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Skip if stop() raced in between. audioQueue.sync is safe: audioQueue only
            // ever dispatches *async* to main, so no deadlock can occur.
            guard self.audioQueue.sync(execute: { self.state != .stopped }) else { return }
            do {
                try self.avEngine.start()
                SessionLog.shared.line("AUDIO-START engine pre-warmed at setup — cold start now, before audio")
            } catch {
                alog.error("AVAudioEngine pre-warm failed: \(error.localizedDescription)")
                self.audioQueue.async { [weak self] in self?.stopOnQueue() }
            }
        }
        alog.info("engine priming (pre-warmed) — target \(Self.targetPrimingFrames) frames")
    }

    private func stopOnQueue() {
        avEngine.stop()
        if let dec = opusDecoder { opus_decoder_destroy(dec); opusDecoder = nil }
        ringBuffer.reset()
        decodeCount        = 0
        diagPrevRtp        = nil
        diagPrevArrival    = nil
        driftAvgFrames     = Double(Self.targetPrimingFrames)
        driftLastCorrection = 0
        driftDrops         = 0
        driftInserts       = 0
        enginePrewarmNanos = 0
        adaptiveTargetFrames = Double(Self.targetPrimingFrames)
        lastUnderrunCount  = 0
        lastUnderrunNanos  = 0
        lastAdaptGrowNanos = 0
        lastAdaptDecayNanos = 0
        ringBuffer.setMaxLatencyFrames(Self.initialMaxLatencyFrames)
        state = .stopped
        alog.info("engine stopped")
    }

    /// Move the ring's latency ceiling to track the current adaptive target (audioQueue).
    private func applyAdaptiveClamp() {
        ringBuffer.setMaxLatencyFrames(Int(adaptiveTargetFrames) + Self.clampMarginFrames)
    }

    private func setupSourceNode() {
        // AudioRingBuffer.read expects exactly 2 non-interleaved float32 buffers.
        // AVAudioFormat(standardFormatWithSampleRate:channels:2) guarantees this;
        // assert here so any future format change surfaces immediately in debug builds.
        assert(pcmFormat.channelCount == 2 && !pcmFormat.isInterleaved,
               "AudioEngine requires non-interleaved stereo PCM (standardFormat, 2ch)")
        let rb = ringBuffer
        let node = AVAudioSourceNode(format: pcmFormat) { _, _, frameCount, abl in
            rb.read(into: abl, frameCount: Int(frameCount))
            return noErr
        }
        sourceNode = node
        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: pcmFormat)
    }

    private func decodeAndWrite(packet: NetworkAudioPacket) {
        guard let dec = opusDecoder else { return }

        // Interleaved stereo float32: max 20 ms × 2 channels = 1920 floats.
        withUnsafeTemporaryAllocation(of: Float.self, capacity: Self.maxFramesPerPacket * 2) { pcmBuf in
            let framesDecoded: Int32 = packet.payload.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress else { return OPUS_INVALID_PACKET }
                return opus_decode_float(
                    dec,
                    ptr.assumingMemoryBound(to: UInt8.self),
                    Int32(raw.count),
                    pcmBuf.baseAddress!,
                    Int32(Self.maxFramesPerPacket),
                    0  // decode_fec = 0: normal decode (not FEC concealment)
                )
            }

            decodeCount += 1
            let isDiag = decodeCount <= 20
            if isDiag || framesDecoded <= 0 {
                let rtpDelta  = diagPrevRtp.map     { Int64(packet.rtpTimestamp &- $0) }
                let arrivalMs = diagPrevArrival.map { Double(packet.localArrivalNanos - $0) / 1_000_000.0 }
                let toc       = packet.payload.first.map { String(format: "0x%02X", $0) } ?? "-"
                let msg = "pkt #\(decodeCount) seq=\(packet.sequenceNumber) "
                        + "Δrtp=\(rtpDelta.map { "\($0)" } ?? "-") "
                        + "Δms=\(arrivalMs.map { String(format: "%.1f", $0) } ?? "-") "
                        + "toc=\(toc) bytes=\(packet.payload.count) frames=\(framesDecoded) "
                        + "ring=\(ringBuffer.availableFrames) "
                        + "underruns=\(ringBuffer.underrunCount) overruns=\(ringBuffer.overrunCount)"
                if isDiag { alog.info("\(msg)") } else { alog.warning("\(msg)") }
                // Persist to the session log so arrival deltas survive the run. Δms is the
                // inter-arrival gap: ~5 ms means real-time delivery, ~1-2 ms means a burst.
                SessionLog.shared.line("AUDIO-DIAG " + msg)
            }
            if isDiag {
                diagPrevRtp     = packet.rtpTimestamp
                diagPrevArrival = packet.localArrivalNanos
            }

            guard framesDecoded > 0 else { return }
            let frames = Int(framesDecoded)

            if state == .running {
                let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

                // Adaptive jitter buffer: grow the target on underruns (we ran too thin to
                // bridge a gap), decay it slowly when the link is calm. The clamp ceiling
                // tracks a fixed margin above the target. We observe underruns reactively
                // here (the render callback counts them; we see the bump on the next packet).
                let underNow = ringBuffer.underrunCount
                if underNow > lastUnderrunCount {
                    lastUnderrunCount = underNow
                    lastUnderrunNanos = now
                    if now &- lastAdaptGrowNanos >= Self.adaptGrowMinIntervalNanos {
                        adaptiveTargetFrames = min(Double(Self.targetCeilFrames),
                                                   adaptiveTargetFrames + Double(Self.adaptGrowFrames))
                        lastAdaptGrowNanos = now
                        applyAdaptiveClamp()
                    }
                } else if now &- lastUnderrunNanos >= Self.adaptDecayQuietNanos,
                          now &- lastAdaptDecayNanos >= Self.adaptDecayIntervalNanos,
                          adaptiveTargetFrames > Double(Self.targetFloorFrames) {
                    adaptiveTargetFrames = max(Double(Self.targetFloorFrames),
                                               adaptiveTargetFrames - Double(Self.adaptDecayFrames))
                    lastAdaptDecayNanos = now
                    applyAdaptiveClamp()
                }

                // Drift servo: hold ring occupancy near the (adaptive) target, correcting the
                // free-running host/output clock drift. Writer-side (readPos untouched),
                // rate-limited, and biases the running average so one correction can't burst.
                driftAvgFrames += (Double(ringBuffer.availableFrames) - driftAvgFrames) * Self.driftAvgAlpha
                if now &- driftLastCorrection >= Self.driftMinIntervalNanos {
                    let target = adaptiveTargetFrames
                    let band   = Double(Self.driftBandFrames)
                    if driftAvgFrames > target + band {
                        // Too full → drop this (freshest) packet to shed ~5 ms of latency.
                        // It was already decoded, so the Opus decoder state stays correct.
                        driftDrops += 1
                        driftLastCorrection = now
                        driftAvgFrames -= Double(frames)
                        return
                    } else if driftAvgFrames < target - band {
                        // Too empty → duplicate this packet to add ~5 ms of cushion.
                        // TODO: use an Opus PLC frame instead of a duplicate once PLC lands.
                        ringBuffer.write(pcmBuf.baseAddress!, frameCount: frames)
                        driftInserts += 1
                        driftLastCorrection = now
                        driftAvgFrames += Double(frames)
                    }
                }
            }

            ringBuffer.write(pcmBuf.baseAddress!, frameCount: frames)

            // Priming → running: the pre-warmed render callback has pulled its first real
            // sample (firstReadNanos set), which means it primed and snapped to target. Flip
            // state and log how much the snap dropped: dropped ≈ 0 ms means the pre-warm fully
            // hid the cold start; a larger value means audio arrived before the engine warmed,
            // but we still start at the target latency (in sync with video) either way.
            if state == .priming, ringBuffer.firstReadNanos != 0 {
                state = .running
                let bufMs  = Double(ringBuffer.availableFrames)  / Self.sampleRate * 1000
                let dropMs = Double(ringBuffer.primeDropFrames)  / Self.sampleRate * 1000
                let warmMs = Double(ringBuffer.firstReadNanos &- enginePrewarmNanos) / 1_000_000.0
                SessionLog.shared.line(String(format:
                    "AUDIO-START playing: ring=%.0fms dropped=%.0fms overruns=%ld  "
                    + "(pre-warm→first audio %.0fms)",
                    bufMs, dropMs, ringBuffer.overrunCount, warmMs))
                alog.info("engine running — \(bufMs, format: .fixed(precision: 1)) ms buffered")
            }
        }
    }
}

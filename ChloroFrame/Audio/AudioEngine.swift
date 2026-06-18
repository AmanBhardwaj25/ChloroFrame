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

private let alog = NoopLog()

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
    // Cap on synthesized frames per gap. Beyond this the dropout is too long to
    // conceal convincingly; we stop filling and let the buffer/servo resync.
    private static let maxConcealFrames:    Int    = 8      // ≤ 40 ms of concealment
    // 60 ms buffered before the (pre-warmed) engine starts consuming, and the initial
    // adaptive-buffer target. Raised from 40 ms because 40 ran too tight in this CoreAudio
    // setup (playback began nearly drained on the first pull).
    private static let targetPrimingFrames: Int    = 2880

    // ── Adaptive jitter buffer (drawdown-sized, fast-grow / slow-floored-shrink) ──────
    // The target occupancy is not fixed. It GROWS fast and reactively when an underrun occurs
    // (the link is jittery and we ran too thin), and SHRINKS only slowly, and only toward a
    // floor the buffer has demonstrably not needed. The floor is sized to the DRAWDOWN — how
    // far occupancy dips below the target — plus a margin and a conservative pad, NOT to the
    // raw low-water level (lowering the target lowers the future low-water by the same amount,
    // so chasing the level walks off a cliff). Grow fast where being wrong is costly (underrun
    // = click); shrink slow where being wrong is cheap (a few ms of latency).
    private static let targetFloorFrames:  Int    = 2400   // 50 ms  — hard min latency
    private static let targetCeilFrames:   Int    = 4560   // 95 ms  — hard max cushion
    private static let clampMarginFrames:  Int    = 1440   // 30 ms  — clamp ceiling above target
    // → max playback latency = ceil + margin = 125 ms. Worst-case lip-sync offset ≈ 125 − ~40
    //   (video age) = ~85 ms audio-behind, still under the ITU-R BT.1359 ~125 ms lag detection
    //   threshold and G.114's 150 ms "transparent" limit.
    private static let adaptGrowFrames:    Int    = 480    // +10 ms per underrun episode (fast attack)
    private static let adaptGrowMinIntervalNanos: UInt64 = 250_000_000     // ≤1 growth / 250 ms
    private static let adaptMarginFrames:  Int    = 480    // 10 ms  — safety margin in `needed`
    private static let adaptPadFrames:     Int    = 240    //  5 ms  — conservative pad above need
    private static let adaptShrinkFrames:  Int    = 96     //  2 ms  — slow-release step
    private static let adaptShrinkIntervalNanos:  UInt64 = 1_000_000_000   // ≤1 shrink step / 1 s
    // Low-water envelope: snaps down to any new occupancy dip, relaxes up slowly so old dips
    // age out of the ~8 s window (≈ 1/alpha packets at ~200 pkt/s).
    private static let adaptLowWaterAlpha: Double = 0.0006
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
    private var decoder: AudioPacketDecoder?

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
    private var lowWaterFrames:       Double = Double(targetPrimingFrames)  // windowed min occupancy
    private var lastUnderrunCount:    Int    = 0
    private var lastAdaptGrowNanos:   UInt64 = 0
    private var lastAdaptShrinkNanos: UInt64 = 0

    // Adaptive-shrink behaviour, chosen per session from the "Prefer smoother audio" setting.
    // Defaults below = low-latency (current behaviour); the smoother profile raises the floor
    // and shrinks gentler so the buffer keeps more cushion (fewer underruns, more latency).
    private var cfgFloorFrames:         Int    = AudioEngine.targetFloorFrames
    private var cfgShrinkFrames:        Int    = AudioEngine.adaptShrinkFrames
    private var cfgShrinkIntervalNanos: UInt64 = AudioEngine.adaptShrinkIntervalNanos
    private var cfgMarginFrames:        Int    = AudioEngine.adaptMarginFrames
    private var cfgPadFrames:           Int    = AudioEngine.adaptPadFrames

    // Diagnostics — track previous packet for delta logging (first 20 packets).
    private var diagPrevRtp:     UInt32? = nil
    private var diagPrevArrival: UInt64? = nil

    // Gap concealment: last decoded RTP sequence, and a running tally for diagnostics.
    private var lastDecodedSeq:  UInt16? = nil
    private var concealedFrames: Int = 0

    // Throttle for the 1 Hz steady-state health log (audioQueue only).
    private var lastSummaryNanos: UInt64 = 0

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

        // Backend chosen at stream start. Apple path falls back to libopus if the
        // AudioConverter can't be created, so a stream never fails to get audio.
        let useApple = UserDefaults.standard.bool(forKey: "useAppleAudioDecoder")
        decoder = (useApple ? AppleOpusDecoder() : nil) ?? LibOpusDecoder()
        guard decoder != nil else {
            throw AudioEngineError.decoderCreationFailed(OPUS_ALLOC_FAIL)
        }
        alog.info("audio decoder backend: \(useApple ? "Apple AudioToolbox" : "libopus")")

        // "Prefer smoother audio" → keep more buffer cushion and shrink it gently, so jitter
        // bursts don't drain the buffer (fewer underruns) at the cost of a little more latency.
        if UserDefaults.standard.bool(forKey: "preferSmootherAudio") {
            cfgFloorFrames         = 3360             // 70 ms floor (vs 50)
            cfgShrinkFrames        = 48               //  1 ms shrink step (vs 2)
            cfgShrinkIntervalNanos = 2_000_000_000    // ≤1 shrink / 2 s (vs 1 s)
            cfgMarginFrames        = 720              // 15 ms safety margin (vs 10)
            cfgPadFrames           = 480              // 10 ms pad (vs 5)
            alog.info("audio buffer: smoother profile (higher floor, gentler shrink)")
        } else {
            cfgFloorFrames         = Self.targetFloorFrames
            cfgShrinkFrames        = Self.adaptShrinkFrames
            cfgShrinkIntervalNanos = Self.adaptShrinkIntervalNanos
            cfgMarginFrames        = Self.adaptMarginFrames
            cfgPadFrames           = Self.adaptPadFrames
            alog.info("audio buffer: low-latency profile")
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
        decoder = nil
        ringBuffer.reset()
        decodeCount        = 0
        lastDecodedSeq     = nil
        concealedFrames    = 0
        lastSummaryNanos   = 0
        diagPrevRtp        = nil
        diagPrevArrival    = nil
        driftAvgFrames     = Double(Self.targetPrimingFrames)
        driftLastCorrection = 0
        driftDrops         = 0
        driftInserts       = 0
        enginePrewarmNanos = 0
        adaptiveTargetFrames = Double(Self.targetPrimingFrames)
        lowWaterFrames     = Double(Self.targetPrimingFrames)
        lastUnderrunCount  = 0
        lastAdaptGrowNanos = 0
        lastAdaptShrinkNanos = 0
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

    /// Reconstruct the `missing` packets immediately before `packet` and write them to the
    /// ring in order: PLC for the older frames, FEC (carried in `packet`) for the most recent.
    /// Must run before the normal decode of `packet` so the Opus decoder state stays continuous.
    private func concealGap(missing: Int, using packet: NetworkAudioPacket, decoder: AudioPacketDecoder) {
        let frameSize = packet.payload.withUnsafeBytes { decoder.frameCount(of: $0) }
        guard frameSize > 0, frameSize <= Self.maxFramesPerPacket else { return }

        let conceal = min(missing, Self.maxConcealFrames)
        withUnsafeTemporaryAllocation(of: Float.self, capacity: Self.maxFramesPerPacket * 2) { buf in
            // Older lost frames have no reachable FEC → model concealment (deep PLC in 1.6.1).
            for _ in 0 ..< (conceal - 1) {
                let n = decoder.decodePLC(frameCount: frameSize, into: buf.baseAddress!)
                if n > 0 { _ = ringBuffer.write(buf.baseAddress!, frameCount: n) }
            }
            // Most recent lost frame: reconstruct from this packet's in-band FEC.
            let n = packet.payload.withUnsafeBytes {
                decoder.decodeFEC(from: $0, frameCount: frameSize, into: buf.baseAddress!)
            }
            if n > 0 { _ = ringBuffer.write(buf.baseAddress!, frameCount: n) }
        }

        concealedFrames += conceal
        if concealedFrames <= 200 {
            alog.info("conceal: gap of \(missing) before seq=\(packet.sequenceNumber) → filled \(conceal) frame(s) (FEC+PLC), total=\(self.concealedFrames)")
        }
    }

    private func decodeAndWrite(packet: NetworkAudioPacket) {
        guard let decoder else { return }

        // Fill any gap before this packet (libopus only): the most recent lost frame
        // is reconstructed from THIS packet's in-band FEC, older ones via PLC. Keeps
        // the timeline continuous so a jitter/loss spike doesn't drain the buffer.
        if decoder.supportsConcealment, let last = lastDecodedSeq {
            let missing = Int(packet.sequenceNumber &- last) - 1   // UInt16 wrap-safe
            if missing > 0 { concealGap(missing: missing, using: packet, decoder: decoder) }
        }
        lastDecodedSeq = packet.sequenceNumber

        // Interleaved stereo float32: max 20 ms × 2 channels = 1920 floats.
        withUnsafeTemporaryAllocation(of: Float.self, capacity: Self.maxFramesPerPacket * 2) { pcmBuf in
            let framesDecoded: Int = packet.payload.withUnsafeBytes { raw in
                decoder.decode(raw, into: pcmBuf.baseAddress!, capacityFrames: Self.maxFramesPerPacket)
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
            var insertDuplicate = false   // drift servo: too-empty → append a faded copy below

            if state == .running {
                let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

                // 1 Hz health snapshot. Watch which counter ticks when a crackle is heard:
                // under/over = ring under/overruns, clamp = samples shed by the latency clamp,
                // dDrop/dIns = drift-servo hard packet drop/duplicate, conc = concealed frames.
                if now &- lastSummaryNanos >= 1_000_000_000 {
                    lastSummaryNanos = now
                    alog.info("AUDIO 1s: under=\(self.ringBuffer.underrunCount) over=\(self.ringBuffer.overrunCount) clamp=\(self.ringBuffer.latencyClampFrames) dDrop=\(self.driftDrops) dIns=\(self.driftInserts) conc=\(self.concealedFrames) ring=\(self.ringBuffer.availableFrames) target=\(Int(self.adaptiveTargetFrames))")
                }

                // Track the windowed low-water mark of actual occupancy: snap down to any new
                // dip, relax up slowly so old dips age out of the window. This gives the
                // drawdown (how deep gaps pull the buffer) without having to risk-probe smaller
                // sizes — we observe the dip while sitting safely at the current target.
                let occ = Double(ringBuffer.availableFrames)
                if occ < lowWaterFrames {
                    lowWaterFrames = occ
                } else {
                    lowWaterFrames += (occ - lowWaterFrames) * Self.adaptLowWaterAlpha
                }

                // Adaptive jitter buffer. GROW fast on underrun (ran too thin); otherwise SHRINK
                // slowly toward a floor sized to the demonstrated need, never below it. `needed`
                // is the dip depth + margin, so the buffer covers the worst observed gap; we
                // creep down by one small step per second and never past `needed + pad`.
                let underNow = ringBuffer.underrunCount
                if underNow > lastUnderrunCount {
                    lastUnderrunCount = underNow
                    if now &- lastAdaptGrowNanos >= Self.adaptGrowMinIntervalNanos {
                        adaptiveTargetFrames = min(Double(Self.targetCeilFrames),
                                                   adaptiveTargetFrames + Double(Self.adaptGrowFrames))
                        lastAdaptGrowNanos = now
                        applyAdaptiveClamp()
                    }
                } else if now &- lastAdaptShrinkNanos >= cfgShrinkIntervalNanos {
                    lastAdaptShrinkNanos = now
                    let drawdown  = max(0, adaptiveTargetFrames - lowWaterFrames)   // dip depth
                    let needed    = drawdown + Double(cfgMarginFrames)
                    let floorT    = max(needed + Double(cfgPadFrames), Double(cfgFloorFrames))
                    if adaptiveTargetFrames > floorT {
                        adaptiveTargetFrames = max(floorT, adaptiveTargetFrames - Double(cfgShrinkFrames))
                        applyAdaptiveClamp()
                    }
                }

                // Drift servo: hold ring occupancy near the (adaptive) target, correcting the
                // free-running host/output clock drift. Writer-side (readPos untouched),
                // rate-limited, and biases the running average so one correction can't burst.
                driftAvgFrames += (Double(ringBuffer.availableFrames) - driftAvgFrames) * Self.driftAvgAlpha
                if now &- driftLastCorrection >= Self.driftMinIntervalNanos {
                    let target = adaptiveTargetFrames
                    let band   = Double(Self.driftBandFrames)
                    if driftAvgFrames > target + band {
                        // Too full → shed ~5 ms of latency. Instead of hard-dropping this packet
                        // (an abrupt splice = click), we still write it below and ask the reader
                        // to shed an equivalent amount via a crossfaded skip. Same latency result,
                        // click-free. Decoder state stays correct (the packet is decoded + written).
                        ringBuffer.requestShed(frames: frames)
                        driftDrops += 1
                        driftLastCorrection = now
                        driftAvgFrames -= Double(frames)
                    } else if driftAvgFrames < target - band {
                        // Too empty → add ~5 ms of cushion by appending a copy of this packet
                        // AFTER the normal write, crossfaded onto the stream so the duplicate
                        // seam doesn't click (see below).
                        insertDuplicate = true
                        driftInserts += 1
                        driftLastCorrection = now
                        driftAvgFrames += Double(frames)
                    }
                }
            }

            ringBuffer.write(pcmBuf.baseAddress!, frameCount: frames)
            if insertDuplicate {
                // Append a faded copy: its head crossfades from the packet's last sample so the
                // duplicate splice is click-free; its tail meets the next real packet normally.
                ringBuffer.write(pcmBuf.baseAddress!, frameCount: frames, fadeInFrames: 64)
            }

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
                alog.info("engine running — \(bufMs) ms buffered")
            }
        }
    }
}

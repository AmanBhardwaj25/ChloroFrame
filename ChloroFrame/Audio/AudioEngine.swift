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

enum AudioEngineState { case stopped, priming, running }

enum AudioEngineError: Error {
    case decoderCreationFailed(Int32)
}

struct AudioEngineStats {
    let state:        AudioEngineState
    let bufferedMs:   Double
    let underrunCount: Int
    let overrunCount: Int
    let decodeCount:  Int
}

final class AudioEngine: @unchecked Sendable {

    private static let sampleRate:          Double = 48000
    // Max frame size passed to opus_decode_float (20 ms at 48 kHz).
    // The actual frame count decoded is what libopus returns, not this ceiling.
    private static let maxFramesPerPacket:  Int    = 960
    // 40 ms buffered before starting AVAudioEngine (avoids first-render underrun).
    private static let targetPrimingFrames: Int    = 1920

    private let ringBuffer = AudioRingBuffer(capacityFrames: 8192)  // ~170 ms
    private let avEngine   = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var opusDecoder: OpaquePointer? = nil

    // audioQueue owns all mutable state below.
    private let audioQueue = DispatchQueue(label: "chloroframe.audio", qos: .userInteractive)
    private var state:       AudioEngineState = .stopped
    private var decodeCount: Int = 0

    // Diagnostics — track previous packet for delta logging (first 20 packets).
    private var diagPrevRtp:     UInt32? = nil
    private var diagPrevArrival: UInt64? = nil

    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    // MARK: - Stats

    var stats: AudioEngineStats {
        audioQueue.sync {
            AudioEngineStats(
                state:         state,
                bufferedMs:    Double(ringBuffer.availableFrames) / Self.sampleRate * 1000,
                underrunCount: ringBuffer.underrunCount,
                overrunCount:  ringBuffer.overrunCount,
                decodeCount:   decodeCount
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
        alog.info("engine priming (libopus) — target \(Self.targetPrimingFrames) frames")
    }

    private func stopOnQueue() {
        avEngine.stop()
        if let dec = opusDecoder { opus_decoder_destroy(dec); opusDecoder = nil }
        ringBuffer.reset()
        decodeCount     = 0
        diagPrevRtp     = nil
        diagPrevArrival = nil
        state = .stopped
        alog.info("engine stopped")
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
            }
            if isDiag {
                diagPrevRtp     = packet.rtpTimestamp
                diagPrevArrival = packet.localArrivalNanos
            }

            guard framesDecoded > 0 else { return }

            ringBuffer.write(pcmBuf.baseAddress!, frameCount: Int(framesDecoded))

            if state == .priming && ringBuffer.availableFrames >= Self.targetPrimingFrames {
                startPlayback()
            }
        }
    }

    private func startPlayback() {
        let rb = ringBuffer
        state = .running   // optimistic — checked again inside the main dispatch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Guard against the race where stop() fires after state = .running above
            // but before this block executes. audioQueue.sync is safe here because
            // audioQueue only ever dispatches *async* to main, so no deadlock can occur.
            guard self.audioQueue.sync(execute: { self.state == .running }) else { return }
            do {
                try self.avEngine.start()
                let ms = Double(rb.availableFrames) / Self.sampleRate * 1000
                alog.info("engine running — \(ms, format: .fixed(precision: 1)) ms buffered")
            } catch {
                alog.error("AVAudioEngine start failed: \(error.localizedDescription)")
                self.audioQueue.async { [weak self] in self?.state = .stopped }
            }
        }
    }
}

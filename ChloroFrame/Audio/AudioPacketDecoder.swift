//
//  AudioPacketDecoder.swift
//  ChloroFrame
//
//  Pluggable Opus → PCM decoders behind a single protocol so the engine can swap
//  backends at stream start:
//
//    • LibOpusDecoder  — the vendored libopus (opus_decode_float). Reference path.
//    • AppleOpusDecoder — macOS's built-in Opus decoder via AudioToolbox's
//      AudioConverter. 100% Apple frameworks, no third-party code. macOS ships an
//      Opus decode component (kAudioFormatOpus is in kAudioFormatProperty_DecodeFormatIDs),
//      so this is a thin wrapper, not a re-implementation of the codec.
//
//  Both produce interleaved stereo Float32 at 48 kHz into the caller's buffer and
//  return the per-channel frame count (<= 0 on failure), matching what the engine's
//  ring buffer expects.
//

import Foundation
import AudioToolbox
import CoreAudioTypes

protocol AudioPacketDecoder: AnyObject {
    /// Decode one compressed packet into interleaved stereo Float32 (48 kHz).
    /// `out` has room for `capacityFrames * 2` floats. Returns frames decoded
    /// per channel, or <= 0 on error.
    func decode(_ payload: UnsafeRawBufferPointer,
                into out: UnsafeMutablePointer<Float>,
                capacityFrames: Int) -> Int

    // MARK: Concealment (loss/jitter resilience)

    /// True if this backend can reconstruct/conceal missing packets (FEC + PLC).
    var supportsConcealment: Bool { get }

    /// Frames-per-channel this packet decodes to, used to size FEC/PLC output. <= 0 if unknown.
    func frameCount(of payload: UnsafeRawBufferPointer) -> Int

    /// Reconstruct the *previous* lost frame from `nextPayload`'s in-band FEC (Opus LBRR).
    /// Falls back to model concealment if the packet carries no FEC. Returns frames, <= 0 on failure.
    func decodeFEC(from nextPayload: UnsafeRawBufferPointer,
                   frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int

    /// Generate one concealment frame from decoder history (deep PLC in libopus 1.6.1).
    func decodePLC(frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int
}

// Backends that can't conceal (e.g. AudioToolbox) inherit these no-ops.
extension AudioPacketDecoder {
    var supportsConcealment: Bool { false }
    func frameCount(of payload: UnsafeRawBufferPointer) -> Int { -1 }
    func decodeFEC(from nextPayload: UnsafeRawBufferPointer,
                   frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int { -1 }
    func decodePLC(frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int { -1 }
}

// MARK: - libopus

final class LibOpusDecoder: AudioPacketDecoder {

    private var dec: OpaquePointer?

    init?(sampleRate: Int32 = 48_000, channels: Int32 = 2) {
        var err: Int32 = 0
        dec = opus_decoder_create(sampleRate, channels, &err)
        guard err == OPUS_OK, dec != nil else { return nil }
    }

    deinit { if let dec { opus_decoder_destroy(dec) } }

    func decode(_ payload: UnsafeRawBufferPointer,
                into out: UnsafeMutablePointer<Float>,
                capacityFrames: Int) -> Int {
        guard let dec, let base = payload.baseAddress else { return -1 }
        return Int(opus_decode_float(
            dec,
            base.assumingMemoryBound(to: UInt8.self),
            Int32(payload.count),
            out,
            Int32(capacityFrames),
            0   // decode_fec = 0: normal decode
        ))
    }

    var supportsConcealment: Bool { true }

    func frameCount(of payload: UnsafeRawBufferPointer) -> Int {
        guard let base = payload.baseAddress else { return -1 }
        return Int(opus_packet_get_nb_samples(
            base.assumingMemoryBound(to: UInt8.self), Int32(payload.count), 48_000))
    }

    func decodeFEC(from nextPayload: UnsafeRawBufferPointer,
                   frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard let dec, let base = nextPayload.baseAddress else { return -1 }
        return Int(opus_decode_float(
            dec,
            base.assumingMemoryBound(to: UInt8.self),
            Int32(nextPayload.count),
            out,
            Int32(frameCount),
            1   // decode_fec = 1: reconstruct the previous lost frame
        ))
    }

    func decodePLC(frameCount: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard let dec else { return -1 }
        // NULL packet → Opus runs concealment (deep PLC when models are compiled in).
        return Int(opus_decode_float(dec, nil, 0, out, Int32(frameCount), 0))
    }
}

// MARK: - Apple AudioToolbox

final class AppleOpusDecoder: AudioPacketDecoder {

    // Mutable state handed to the C input callback. A class so we can pass a
    // stable pointer through AudioConverterFillComplexBuffer's userData.
    final class Feed {
        var data = UnsafeRawBufferPointer(start: nil, count: 0)
        var channels: UInt32 = 2
        var consumed = false
        let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        deinit { desc.deallocate() }
    }

    private var converter: AudioConverterRef?
    private let channels: UInt32
    private let feed = Feed()

    init?(sampleRate: Double = 48_000, channels: UInt32 = 2) {
        self.channels = channels
        feed.channels = channels

        var src = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)

        // Interleaved Float32 to match the ring buffer's write layout.
        var dst = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)

        var conv: AudioConverterRef?
        guard AudioConverterNew(&src, &dst, &conv) == noErr, let conv else { return nil }
        converter = conv

        // Hand the decoder an OpusHead so it knows channel count / sample rate /
        // pre-skip. The stream is raw Opus packets (no Ogg container).
        var cookie = Self.opusHead(channels: channels, sampleRate: UInt32(sampleRate))
        _ = AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                      UInt32(cookie.count), &cookie)
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    func decode(_ payload: UnsafeRawBufferPointer,
                into out: UnsafeMutablePointer<Float>,
                capacityFrames: Int) -> Int {
        guard let converter, payload.baseAddress != nil else { return -1 }

        feed.data = payload
        feed.consumed = false
        feed.desc.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(payload.count))

        var ioPackets = UInt32(capacityFrames)   // PCM: 1 packet == 1 frame
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(capacityFrames) * channels * 4,
                mData: UnsafeMutableRawPointer(out)))

        let status = AudioConverterFillComplexBuffer(
            converter, opusInputProc,
            Unmanaged.passUnretained(feed).toOpaque(),
            &ioPackets, &abl, nil)

        // noErr or a benign "no more input" return both yield the frames produced.
        guard ioPackets > 0 else { return status == noErr ? 0 : -1 }
        return Int(ioPackets)
    }

    /// 19-byte OpusHead identification header (RFC 7845 §5.1), used as the
    /// AudioConverter decompression magic cookie.
    private static func opusHead(channels: UInt32, sampleRate: UInt32) -> [UInt8] {
        var c = Array("OpusHead".utf8)        // 8 bytes magic
        c.append(1)                           // version
        c.append(UInt8(channels))             // channel count
        c.append(contentsOf: [0x00, 0x00])    // pre-skip (LE) = 0, continuous stream
        c.append(contentsOf: [UInt8(sampleRate & 0xff),
                              UInt8((sampleRate >> 8) & 0xff),
                              UInt8((sampleRate >> 16) & 0xff),
                              UInt8((sampleRate >> 24) & 0xff)])  // input sample rate (LE)
        c.append(contentsOf: [0x00, 0x00])    // output gain (LE)
        c.append(0)                           // channel mapping family 0 (mono/stereo)
        return c
    }
}

// Returned by the input proc to mean "no more data for now". Must be NON-zero:
// returning noErr with 0 packets signals end-of-stream, which drops the converter
// into a terminal state so it never decodes another packet. A non-zero status
// leaves it alive across packets; decode() treats any ioPackets > 0 as success.
private let kNoMoreOpusData: OSStatus = 1

// C input callback: vends the single pending Opus packet once. On the converter's
// follow-up call (it always asks again) we report "no more data" without EOF.
private func opusInputProc(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let feed = Unmanaged<AppleOpusDecoder.Feed>.fromOpaque(userData!).takeUnretainedValue()

    if feed.consumed || feed.data.baseAddress == nil {
        ioNumberDataPackets.pointee = 0
        return kNoMoreOpusData
    }
    feed.consumed = true

    ioNumberDataPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = feed.channels
    ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.data.count)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: feed.data.baseAddress)
    outPacketDescription?.pointee = feed.desc
    return noErr
}

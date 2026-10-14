//
//  PyroWaveTransportRules.swift
//  ChloroFrame
//
//  The pure decisions the video receive path makes for PyroWave frames, split out of
//  RTPVideoReceiver so they can be unit tested without a socket or a GPU.
//  See design/pyrowave-implementation-plan.md D6.
//

import Foundation

nonisolated enum PyroWaveFrameTrim {

    enum Failure: Error, Equatable {
        /// The packet size leaves no room for a payload.
        case badPacketSize(Int)
        /// `lastPayloadLen` is 0 (header missing or extended) or larger than one payload.
        case badLastPayloadLen(Int)
        /// The trimmed frame cannot even hold a sequence header (8 bytes).
        case tooShort(Int)
        /// Record framing is made of 32-bit words.
        case notWordAligned(Int)
    }

    /// Payload bytes carried by one data shard: `packetSize` minus the 16-byte NV_VIDEO_PACKET.
    /// Matches vibeshine's `payload_blocksize`.
    static func payloadBytes(packetSize: Int) -> Int { packetSize - 16 }

    /// The last data packet is zero padded to full size on the wire. `lastPayloadLen` is how
    /// many of its payload bytes are real, so the real frame is the assembled bytes minus the
    /// padding `P - lastPayloadLen`. Returns the number of leading bytes to keep.
    static func validLength(assembledCount: Int, lastPayloadLen: Int, packetSize: Int) -> Result<Int, Failure> {
        let p = payloadBytes(packetSize: packetSize)
        guard p > 0 else { return .failure(.badPacketSize(packetSize)) }
        guard lastPayloadLen > 0, lastPayloadLen <= p else { return .failure(.badLastPayloadLen(lastPayloadLen)) }
        let valid = assembledCount - (p - lastPayloadLen)
        guard valid >= 8 else { return .failure(.tooShort(valid)) }
        guard valid % 4 == 0 else { return .failure(.notWordAligned(valid)) }
        return .success(valid)
    }
}

/// What the receive path does when the queue reports a frame it could not assemble.
nonisolated enum VideoLossPolicy {

    enum Action: Equatable {
        /// H.264, HEVC and AV1: P-frames after the loss are undecodable, so drop until the next
        /// IDR and ask the host for one. The IDR also resets the playout clock.
        case waitForIdrAndRequest
        /// PyroWave: every frame is intra-only. Count it and carry on. No IDR request, no
        /// `waitingForIdr`, and (since no IDR ever follows) no clock reset, which would empty
        /// the renderer queue on every loss.
        case countOnly
    }

    static func action(for codec: VideoCodec) -> Action {
        codec == .pyrowave ? .countOnly : .waitForIdrAndRequest
    }
}

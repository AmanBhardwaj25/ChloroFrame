//
//  AudioPacket.swift
//  ChloroFrame
//

import Foundation

struct NetworkAudioPacket {
    let sequenceNumber:   UInt16
    let rtpTimestamp:     UInt32
    let localArrivalNanos: UInt64   // monotonic nanoseconds — for future jitter buffer
    let payload:          Data      // raw Opus bytes after the 12-byte RTP header
}

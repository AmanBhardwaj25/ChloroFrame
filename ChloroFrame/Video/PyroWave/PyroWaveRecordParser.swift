//
//  PyroWaveRecordParser.swift
//  ChloroFrame
//
//  Splits a trimmed, reassembled PyroWave frame into the byte ranges that may be
//  pushed into the decoder, enforcing the receiver rules of vibeshine's
//  docs/pyrowave-protocol.md ("Record framing"). Pure logic: no GPU, no network.
//

import Foundation

nonisolated struct PyroWaveStreamFormat: Equatable {
    let width: Int
    let height: Int
    let chroma444: Bool
    let bitDepth: Int          // 8 or 10; not in the bitstream, comes from negotiation
}

nonisolated enum PyroWaveRecordParser {
    struct Frame: Equatable {
        var sequence: UInt8            // 3-bit sequence from the sequence header
        var totalBlocks: Int           // from the sequence header
        var records: [Range<Int>]      // sequence header first, then block records, in arrival order
        var blockRecordCount: Int
        var paddingBytes: Int          // stats only
    }

    enum Failure: Error, Equatable {
        case lengthPrefixedFraming      // first word has bit 31 clear
        case notWordAligned
        case truncatedRecord(offset: Int)
        case missingSequenceHeader
        case secondSequenceHeader(offset: Int)
        case unknownSequenceCode(UInt32)
        case dimensionMismatch(width: Int, height: Int)
        case chromaMismatch
        case shortBlock(offset: Int)    // payload_words < 2 (the hang case)
        case sequenceMismatch(offset: Int)
        case paddingOverrun(offset: Int)
    }

    /// First word of a padding record. Never a valid sequence header for a
    /// negotiated stream (it would mean a 16384 pixel wide image with code 3).
    static let paddingMagic: UInt32 = 0xFFFF_FFFF

    private static let headerBytes = 8

    /// Walks the records of `bytes` (one frame, already trimmed to `lastPayloadLen`).
    /// Never reads outside `bytes`. Padding records are skipped and never appear in
    /// `Frame.records`, because the C parser would read them as a bogus sequence header.
    /// Whether every block index is in range is left to the C parser, which checks it
    /// in `BitstreamParser::push_packet`; a failure there also drops the frame.
    static func parse(_ bytes: UnsafeRawBufferPointer,
                      expected: PyroWaveStreamFormat) -> Result<Frame, Failure> {
        let count = bytes.count
        if count % 4 != 0 { return .failure(.notWordAligned) }
        if count < headerBytes { return .failure(.missingSequenceHeader) }

        // A packet count in a length-prefixed frame never has bit 31 set, while a
        // record-framed frame starts with a sequence header or a padding record.
        if readWord(bytes, 0) & 0x8000_0000 == 0 { return .failure(.lengthPrefixedFraming) }

        var records: [Range<Int>] = []
        var sequenceHeaderSeen = false
        var sequence: UInt32 = 0
        var totalBlocks = 0
        var blockRecords = 0
        var paddingBytes = 0
        var pos = 0

        while pos < count {
            if count - pos < headerBytes { return .failure(.truncatedRecord(offset: pos)) }
            let w0 = readWord(bytes, pos)
            let w1 = readWord(bytes, pos + 4)

            if w0 == paddingMagic {
                // 8 + 4 * N bytes, N zero words (their value is not verified).
                let (payload, overflow) = Int(w1).multipliedReportingOverflow(by: 4)
                guard !overflow, payload <= count - pos - headerBytes else {
                    return .failure(.paddingOverrun(offset: pos))
                }
                let length = headerBytes + payload
                paddingBytes += length
                pos += length
                continue
            }

            if w0 & 0x8000_0000 != 0 {
                if sequenceHeaderSeen { return .failure(.secondSequenceHeader(offset: pos)) }
                let code = (w1 >> 24) & 0x3
                if code != 0 { return .failure(.unknownSequenceCode(code)) }
                let width = Int(w0 & 0x3FFF) + 1
                let height = Int((w0 >> 14) & 0x3FFF) + 1
                if width != expected.width || height != expected.height {
                    return .failure(.dimensionMismatch(width: width, height: height))
                }
                if ((w1 >> 26) & 0x1 != 0) != expected.chroma444 {
                    return .failure(.chromaMismatch)
                }
                sequenceHeaderSeen = true
                sequence = (w0 >> 28) & 0x7
                totalBlocks = Int(w1 & 0xFF_FFFF)
                records.append(pos..<pos + headerBytes)
                pos += headerBytes
                continue
            }

            // Block record.
            if !sequenceHeaderSeen { return .failure(.missingSequenceHeader) }
            let payloadWords = Int((w0 >> 16) & 0xFFF)
            if payloadWords < 2 { return .failure(.shortBlock(offset: pos)) }
            let length = payloadWords * 4
            if length > count - pos { return .failure(.truncatedRecord(offset: pos)) }
            if (w0 >> 28) & 0x7 != sequence { return .failure(.sequenceMismatch(offset: pos)) }
            records.append(pos..<pos + length)
            blockRecords += 1
            pos += length
        }

        if !sequenceHeaderSeen { return .failure(.missingSequenceHeader) }
        return .success(Frame(sequence: UInt8(sequence),
                              totalBlocks: totalBlocks,
                              records: records,
                              blockRecordCount: blockRecords,
                              paddingBytes: paddingBytes))
    }

    /// Merges ranges that touch (no padding between them) so the decoder is pushed
    /// fewer, larger chunks. The C parser loops over concatenated records, so this
    /// is equivalent to pushing every record on its own.
    static func coalesced(_ records: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        merged.reserveCapacity(records.count)
        for range in records {
            if let last = merged.last, last.upperBound == range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    @inline(__always)
    private static func readWord(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

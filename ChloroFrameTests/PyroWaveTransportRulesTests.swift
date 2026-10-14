//
//  PyroWaveTransportRulesTests.swift
//  ChloroFrameTests
//
//  D6: the pure receive-path rules (short header parsing, tail trimming, loss policy) and the
//  C15 severity bands.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveTransportRulesTests: XCTestCase {

    // MARK: - FrameMeta

    private func header(first: UInt8 = 0x01, type: UInt8 = 2, last: Int, critical: Int) -> [UInt8] {
        [first, 0, 0, type, UInt8(last & 0xFF), UInt8(last >> 8), UInt8(critical & 0xFF), UInt8(critical >> 8)]
    }

    func testShortHeaderFieldsAreLittleEndianAtTheSpecOffsets() {
        let slot = [UInt8](repeating: 0xEE, count: 32) + header(last: 0x0123, critical: 0x0245) + [0xAA, 0xBB]
        let meta = FrameMeta.parseShortHeader(slot, headerOffset: 32)
        XCTAssertEqual(meta.frameType, 2)
        XCTAssertEqual(meta.lastPayloadLen, 0x0123)
        XCTAssertEqual(meta.pyroWaveCriticalPackets, 0x0245)
    }

    func testExtendedHeaderKeepsFrameTypeButNoPyroWaveFields() {
        var slot = header(first: 0x81, type: 5, last: 900, critical: 7)
        slot += [UInt8](repeating: 0, count: 36)
        let meta = FrameMeta.parseShortHeader(slot, headerOffset: 0)
        XCTAssertEqual(meta.frameType, 5)
        XCTAssertEqual(meta.lastPayloadLen, 0)
        XCTAssertEqual(meta.pyroWaveCriticalPackets, 0)
    }

    func testTruncatedSlotIsBoundsChecked() {
        // Type byte present, length and critical bytes cut off.
        let slot: [UInt8] = [0x01, 0, 0, 2, 0x10]
        let meta = FrameMeta.parseShortHeader(slot, headerOffset: 0)
        XCTAssertEqual(meta.frameType, 2)
        XCTAssertEqual(meta.lastPayloadLen, 0)
        XCTAssertEqual(meta.pyroWaveCriticalPackets, 0)
        // Header offset beyond the slot: the existing default (P frame), no crash.
        XCTAssertEqual(FrameMeta.parseShortHeader([1, 2, 3], headerOffset: 40), FrameMeta())
    }

    func testDefaultMetaMatchesTheOldNoHeaderBehavior() {
        XCTAssertEqual(FrameMeta().frameType, 1)
        XCTAssertEqual(FrameMeta().lastPayloadLen, 0)
    }

    // MARK: - Trimming

    private let packetSize = 1392            // payload per shard: 1376

    func testTrimRemovesExactlyTheZeroPadding() {
        // 3 shards of 1376, the first 8 bytes of the first are the frame header, so the
        // assembled buffer is 3 * 1376 - 8 bytes. Real data ends 100 bytes into the last shard.
        let p = 1376
        let assembled = 3 * p - 8
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: assembled, lastPayloadLen: 100, packetSize: packetSize),
                       .success(assembled - (p - 100)))
    }

    func testFullLastShardTrimsNothing() {
        let p = 1376
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 2 * p - 8, lastPayloadLen: p, packetSize: packetSize),
                       .success(2 * p - 8))
    }

    func testTrimRejectsUnknownOrImpossibleLastPayloadLen() {
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 4000, lastPayloadLen: 0, packetSize: packetSize),
                       .failure(.badLastPayloadLen(0)))
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 4000, lastPayloadLen: 1377, packetSize: packetSize),
                       .failure(.badLastPayloadLen(1377)))
    }

    func testTrimRejectsTooShortAndMisalignedFrames() {
        // Trimmed length 4 is under a sequence header.
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 1376 - 8, lastPayloadLen: 4 + 8, packetSize: packetSize),
                       .failure(.tooShort(4)))
        // Trimmed length 10 is not a whole number of words.
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 1376 - 8, lastPayloadLen: 10 + 8, packetSize: packetSize),
                       .failure(.notWordAligned(10)))
        XCTAssertEqual(PyroWaveFrameTrim.validLength(assembledCount: 100, lastPayloadLen: 10, packetSize: 16),
                       .failure(.badPacketSize(16)))
    }

    /// The reason trimming exists: an untrimmed tail is rejected by the record parser.
    func testUntrimmedTailIsRejectedByTheParserAndTrimmedIsAccepted() throws {
        let format = PyroWaveStreamFormat(width: 64, height: 64, chroma444: false, bitDepth: 8)
        // Sequence header (64x64, 4:2:0, sequence 0, total_blocks 1) + one 4-word block record.
        var frame = [UInt8]()
        func word(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { frame.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        word(UInt32(63) | UInt32(63) << 14 | 1 << 31)   // extended, 64x64, sequence 0
        word(1)                                         // total_blocks 1, code 0, 4:2:0
        word(UInt32(0xFFFF) | UInt32(4) << 16)          // ballot, payload_words = 4, sequence 0
        word(0)                                         // quant_code 0, block_index 0
        word(0xDEADBEEF); word(0xCAFEBABE)
        let realCount = frame.count
        // Pad the way the host does: to a full shard.
        let p = PyroWaveFrameTrim.payloadBytes(packetSize: packetSize)
        let padded = frame + [UInt8](repeating: 0, count: p - realCount)

        let untrimmed = padded.withUnsafeBytes { PyroWaveRecordParser.parse($0, expected: format) }
        XCTAssertEqual(untrimmed, .failure(.shortBlock(offset: realCount)))

        let valid = try PyroWaveFrameTrim.validLength(assembledCount: padded.count, lastPayloadLen: realCount, packetSize: packetSize).get()
        XCTAssertEqual(valid, realCount)
        let trimmed = padded.prefix(valid).withUnsafeBytes { PyroWaveRecordParser.parse($0, expected: format) }
        if case .failure(let f) = trimmed { XCTFail("trimmed frame rejected: \(f)") }
    }

    // MARK: - Loss policy

    func testOnlyPyroWaveSkipsIdrRecovery() {
        XCTAssertEqual(VideoLossPolicy.action(for: .pyrowave), .countOnly)
        XCTAssertEqual(VideoLossPolicy.action(for: .h264), .waitForIdrAndRequest)
        XCTAssertEqual(VideoLossPolicy.action(for: .hevc), .waitForIdrAndRequest)
        XCTAssertEqual(VideoLossPolicy.action(for: .av1), .waitForIdrAndRequest)
    }

    // MARK: - Color from the announced encoderCscMode

    func testEncoderCscModeMappingMatchesTheHost() {
        // What SDPBuilder sends for PyroWave SDR is BT.709 limited.
        XCTAssertEqual(SDPBuilder.encoderCscMode(codec: .pyrowave, hdr: false), 2)
        let sdr = PlanarColorParams.forEncoderCscMode(2, bitDepth: 8, hdr: false)
        XCTAssertEqual(sdr, PlanarColorParams(bitDepth: 8, fullRange: false, matrix: .bt709, transfer: .sdr))

        // The other codecs' values are unchanged by the refactor.
        XCTAssertEqual(SDPBuilder.encoderCscMode(codec: .hevc, hdr: false), 0)
        XCTAssertEqual(SDPBuilder.encoderCscMode(codec: .h264, hdr: false), 0)
        XCTAssertEqual(SDPBuilder.encoderCscMode(codec: .av1, hdr: false), 0)
        XCTAssertEqual(SDPBuilder.encoderCscMode(codec: .hevc, hdr: true), 4)

        XCTAssertEqual(PlanarColorParams.forEncoderCscMode(0, bitDepth: 8, hdr: false).matrix, .bt601)
        XCTAssertTrue(PlanarColorParams.forEncoderCscMode(3, bitDepth: 8, hdr: false).fullRange)
        XCTAssertEqual(PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: true).transfer, .pq)
    }

    // MARK: - C15 severity bands (plan D5b table)

    private func c15(_ ms: Double?) -> PyroWaveCheckResult {
        var i = PyroWaveAuditInputs()
        i.gpuDecodeMs = ms
        return PyroWaveReadinessAudit.evaluate(i).results.first { $0.id == "C15" }!
    }

    func testC15Bands() {
        XCTAssertEqual(c15(0.3).outcome, .pass)
        XCTAssertEqual(c15(1.99).outcome, .pass)

        // 2 to 4 ms is a warning, both ends inclusive.
        for ms in [2.0, 3.0, 4.0] {
            let r = c15(ms)
            XCTAssertEqual(r.severity, .warning, "\(ms) ms")
            XCTAssertTrue(r.isWarning, "\(ms) ms")
            XCTAssertFalse(r.failedAsBlocker, "\(ms) ms")
        }

        // Over 4 ms blocks.
        for ms in [4.01, 7.5] {
            let r = c15(ms)
            XCTAssertEqual(r.severity, .blocker, "\(ms) ms")
            XCTAssertTrue(r.failedAsBlocker, "\(ms) ms")
        }
    }

    func testC15BenchmarkThatCouldNotRunNeverBlocksOrWarns() {
        let r = c15(nil)
        XCTAssertFalse(r.failedAsBlocker)
        XCTAssertFalse(r.isWarning)
    }
}

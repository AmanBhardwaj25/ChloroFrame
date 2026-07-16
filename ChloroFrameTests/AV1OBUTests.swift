//
//  AV1OBUTests.swift
//  ChloroFrameTests
//
//  Unit tests for the AV1 setup-only bitstream parsing: OBU walking, leb128,
//  sequence-header parsing, temporal-unit trimming, and av1C format-description
//  construction. Driven by real frames captured from a live Sunshine host
//  (AV1Fixtures) so the bit-walk is checked against ground truth, not assumptions.
//

import XCTest
import CoreMedia
@testable import ChloroFrame

final class AV1OBUTests: XCTestCase {

    // Run a closure with the fixture as a UInt8 buffer.
    private func withBuf<R>(_ data: Data, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        data.withUnsafeBytes { raw in body(raw.bindMemory(to: UInt8.self)) }
    }

    // MARK: leb128

    func testLeb128SingleByte() {
        let bytes: [UInt8] = [0x00, 0x7F]
        bytes.withUnsafeBufferPointer { buf in
            var i = 0
            XCTAssertEqual(AV1OBU.readLeb128(buf, &i), 0); XCTAssertEqual(i, 1)
            XCTAssertEqual(AV1OBU.readLeb128(buf, &i), 127); XCTAssertEqual(i, 2)
        }
    }

    func testLeb128MultiByte() {
        // 0x80 0x01 = 128; 0xAC 0x02 = 300.
        ([0x80, 0x01] as [UInt8]).withUnsafeBufferPointer { buf in
            var i = 0; XCTAssertEqual(AV1OBU.readLeb128(buf, &i), 128); XCTAssertEqual(i, 2)
        }
        ([0xAC, 0x02] as [UInt8]).withUnsafeBufferPointer { buf in
            var i = 0; XCTAssertEqual(AV1OBU.readLeb128(buf, &i), 300); XCTAssertEqual(i, 2)
        }
    }

    func testLeb128Truncated() {
        // Continuation bit set but buffer ends -> nil, no out-of-bounds read.
        ([0x80] as [UInt8]).withUnsafeBufferPointer { buf in
            var i = 0; XCTAssertNil(AV1OBU.readLeb128(buf, &i))
        }
    }

    func testLeb128Overlong() {
        // 9 continuation bytes -> invalid.
        ([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01] as [UInt8]).withUnsafeBufferPointer { buf in
            var i = 0; XCTAssertNil(AV1OBU.readLeb128(buf, &i))
        }
    }

    // MARK: sequence-header parsing (real fixture = ground truth)

    func testParseSequenceHeaderFromKeyFrame() {
        let seq = withBuf(AV1Fixtures.keyFrame) { AV1OBU.parseSequenceHeader(in: $0) }
        let s = try! XCTUnwrap(seq)
        XCTAssertEqual(s.maxWidth, 3024)
        XCTAssertEqual(s.maxHeight, 1890)
        XCTAssertEqual(s.seqProfile, 0)
        XCTAssertEqual(s.bitDepth, 8)
        XCTAssertFalse(s.highBitdepth)
        XCTAssertFalse(s.monochrome)
        XCTAssertTrue(s.subsamplingX)   // 4:2:0
        XCTAssertTrue(s.subsamplingY)
        XCTAssertEqual(s.obuBytes.count, 17) // complete seq-header OBU (header + size + payload)
    }

    func testParseSequenceHeaderReturnsNilOnPFrame() {
        // A P-frame's temporal unit has no sequence header (TD then FRAME).
        let seq = withBuf(AV1Fixtures.pFrame) { AV1OBU.parseSequenceHeader(in: $0) }
        XCTAssertNil(seq)
    }

    // MARK: key-frame fallback predicate

    func testHasLeadingSequenceHeader() {
        XCTAssertTrue(withBuf(AV1Fixtures.keyFrame) { AV1OBU.hasLeadingSequenceHeader($0) })
        XCTAssertFalse(withBuf(AV1Fixtures.pFrame) { AV1OBU.hasLeadingSequenceHeader($0) })
    }

    // MARK: temporal-unit trimming (the bug that caused the blank screen)

    func testValidTemporalUnitLengthTrimsPadding() {
        // Both fixtures are real temporal units zero-padded to a 1368-byte shard.
        // Concrete valid lengths for these captures; the invariants below are what
        // actually matters (a re-capture would change the constants, not the rules).
        assertTrim(AV1Fixtures.keyFrame, expected: 563)
        assertTrim(AV1Fixtures.pFrame, expected: 81)
    }

    private func assertTrim(_ frame: Data, expected: Int) {
        XCTAssertEqual(frame.count, 1368, "fixture should be padded to shard size")
        let len = withBuf(frame) { AV1OBU.validTemporalUnitLength($0) }
        XCTAssertEqual(len, expected)
        // Invariants independent of the exact capture:
        XCTAssertGreaterThan(len, 0)
        XCTAssertLessThan(len, frame.count, "trimming must drop the padding")
        XCTAssertEqual(frame[len], 0x00, "padding begins right after the valid OBUs")
    }

    // MARK: av1C / CMFormatDescription

    func testCreateAV1FormatDescription() {
        let seq = withBuf(AV1Fixtures.keyFrame) { AV1OBU.parseSequenceHeader(in: $0) }!
        let fmt = try! XCTUnwrap(VideoFormatHelper.createAV1FormatDescription(seq: seq, isHDR: false))
        XCTAssertEqual(CMFormatDescriptionGetMediaType(fmt), kCMMediaType_Video)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMVideoCodecType_AV1)
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        XCTAssertEqual(dims.width, 3024)
        XCTAssertEqual(dims.height, 1890)
    }

    func testCreateAV1FormatDescriptionHDRTags() {
        let seq = withBuf(AV1Fixtures.keyFrame) { AV1OBU.parseSequenceHeader(in: $0) }!
        let fmt = try! XCTUnwrap(VideoFormatHelper.createAV1FormatDescription(seq: seq, isHDR: true))
        let ext = CMFormatDescriptionGetExtensions(fmt) as? [CFString: Any]
        // HDR10: PQ transfer + BT.2020 primaries/matrix attached to the format desc.
        XCTAssertEqual(ext?[kCMFormatDescriptionExtension_TransferFunction] as! CFString?,
                       kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        XCTAssertEqual(ext?[kCMFormatDescriptionExtension_ColorPrimaries] as! CFString?,
                       kCMFormatDescriptionColorPrimaries_ITU_R_2020)
        XCTAssertEqual(ext?[kCMFormatDescriptionExtension_YCbCrMatrix] as! CFString?,
                       kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
    }
}

final class ServerCapabilityTests: XCTestCase {
    private func info(codecModeSupport: Int) -> ServerInfo {
        ServerInfo(hostname: "h", gpuType: "g", serverUniqueId: "u",
                   pairStatus: 1, codecModeSupport: codecModeSupport)
    }

    func testSupportsAV1Main8() {
        XCTAssertTrue(info(codecModeSupport: 0x00010000).supportsAV1Main8)
        XCTAssertTrue(info(codecModeSupport: 0x00010003).supportsAV1Main8)  // with H.264 bits too
        XCTAssertFalse(info(codecModeSupport: 0x00020000).supportsAV1Main8) // AV1 Main10 only
        XCTAssertFalse(info(codecModeSupport: 0x00000003).supportsAV1Main8) // H.264/HEVC only
    }

    func testSupportsAV1Main10() {
        XCTAssertTrue(info(codecModeSupport: 0x00020000).supportsAV1Main10)
        XCTAssertFalse(info(codecModeSupport: 0x00010000).supportsAV1Main10) // Main8 only
        XCTAssertFalse(info(codecModeSupport: 0x00000003).supportsAV1Main10) // H.264/HEVC only
    }
}

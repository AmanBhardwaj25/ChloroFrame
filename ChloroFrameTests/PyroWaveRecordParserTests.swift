//
//  PyroWaveRecordParserTests.swift
//  ChloroFrameTests
//
//  Frame builders mirror make_bitstream() in vibeshine/tests/unit/test_pyrowave_policy.cpp.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveRecordParserTests: XCTestCase {

    private typealias Parser = PyroWaveRecordParser

    private let format = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 8)

    // MARK: Builders

    private func word(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    private func sequenceHeader(width: Int = 1920, height: Int = 1080, sequence: UInt32 = 0,
                                totalBlocks: Int = 0, code: UInt32 = 0, chroma444: Bool = false) -> [UInt8] {
        let w0 = UInt32(width - 1) | (UInt32(height - 1) << 14) | (sequence << 28) | (1 << 31)
        let w1 = UInt32(totalBlocks) | (code << 24) | (chroma444 ? 1 << 26 : 0)
        return word(w0) + word(w1)
    }

    /// A block record of `words` 32-bit words (header included), payload filled with a marker.
    private func block(words: Int, index: Int = 0, sequence: UInt32 = 0) -> [UInt8] {
        let w0 = 0x5A5A | (UInt32(words) << 16) | (sequence << 28)
        let w1 = 7 | (UInt32(index) << 8)
        var out = word(w0) + word(w1)
        if words > 2 {
            for i in 2..<words { out += word(UInt32(index << 12 | i)) }
        }
        return out
    }

    /// `8 + 4 * n` bytes.
    private func padding(words n: Int) -> [UInt8] {
        word(0xFFFF_FFFF) + word(UInt32(n)) + [UInt8](repeating: 0, count: 4 * n)
    }

    private func parse(_ bytes: [UInt8], expected: PyroWaveStreamFormat? = nil)
        -> Result<Parser.Frame, Parser.Failure> {
        bytes.withUnsafeBytes { Parser.parse($0, expected: expected ?? format) }
    }

    private func assertFailure(_ bytes: [UInt8], _ expected: Parser.Failure,
                               format: PyroWaveStreamFormat? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch parse(bytes, expected: format) {
        case .success(let frame):
            XCTFail("expected \(expected), parsed \(frame)", file: file, line: line)
        case .failure(let failure):
            XCTAssertEqual(failure, expected, file: file, line: line)
        }
    }

    private func assertFrame(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line)
        -> Parser.Frame? {
        switch parse(bytes) {
        case .success(let frame): return frame
        case .failure(let failure):
            XCTFail("unexpected failure \(failure)", file: file, line: line)
            return nil
        }
    }

    // MARK: Valid frames

    func testSequenceHeaderAndThreeBlocks() throws {
        let bytes = sequenceHeader(sequence: 5, totalBlocks: 3)
            + block(words: 10, index: 0, sequence: 5)
            + block(words: 2, index: 1, sequence: 5)
            + block(words: 30, index: 2, sequence: 5)
        let frame = try XCTUnwrap(assertFrame(bytes))
        XCTAssertEqual(frame.sequence, 5)
        XCTAssertEqual(frame.totalBlocks, 3)
        XCTAssertEqual(frame.blockRecordCount, 3)
        XCTAssertEqual(frame.paddingBytes, 0)
        XCTAssertEqual(frame.records, [0..<8, 8..<48, 48..<56, 56..<176])
        XCTAssertEqual(frame.records.last?.upperBound, bytes.count)
    }

    func testPaddingBetweenBlocksIsSkipped() throws {
        let header = sequenceHeader(totalBlocks: 2)
        let a = block(words: 4, index: 0)
        let pad = padding(words: 3)
        let b = block(words: 6, index: 1)
        let frame = try XCTUnwrap(assertFrame(header + pad + a + pad + b))
        XCTAssertEqual(frame.blockRecordCount, 2)
        XCTAssertEqual(frame.paddingBytes, 2 * pad.count)
        let aStart = 8 + pad.count
        let bStart = aStart + a.count + pad.count
        XCTAssertEqual(frame.records, [0..<8, aStart..<aStart + a.count, bStart..<bStart + b.count])
    }

    func testPaddingAtTheEnd() throws {
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 5) + padding(words: 17)
        let frame = try XCTUnwrap(assertFrame(bytes))
        XCTAssertEqual(frame.blockRecordCount, 1)
        XCTAssertEqual(frame.paddingBytes, 8 + 17 * 4)
        XCTAssertEqual(frame.records.last, 8..<28)
    }

    func testMinimalPaddingHasNoZeroWords() throws {
        let bytes = sequenceHeader(totalBlocks: 1) + padding(words: 0) + block(words: 2)
        XCTAssertEqual(padding(words: 0).count, 8)
        let frame = try XCTUnwrap(assertFrame(bytes))
        XCTAssertEqual(frame.paddingBytes, 8)
        XCTAssertEqual(frame.records, [0..<8, 16..<24])
    }

    func testPaddingBeforeTheSequenceHeaderIsAccepted() throws {
        let bytes = padding(words: 2) + sequenceHeader(totalBlocks: 1) + block(words: 3)
        let frame = try XCTUnwrap(assertFrame(bytes))
        XCTAssertEqual(frame.records.first, 16..<24)
        XCTAssertEqual(frame.blockRecordCount, 1)
    }

    func testHeaderOnlyFrameIsValid() throws {
        let frame = try XCTUnwrap(assertFrame(sequenceHeader(totalBlocks: 0)))
        XCTAssertEqual(frame.records, [0..<8])
        XCTAssertEqual(frame.blockRecordCount, 0)
    }

    func test444FrameMatchesA444Stream() throws {
        let f444 = PyroWaveStreamFormat(width: 3840, height: 2160, chroma444: true, bitDepth: 8)
        let bytes = sequenceHeader(width: 3840, height: 2160, totalBlocks: 1, chroma444: true) + block(words: 4)
        guard case .success(let frame) = parse(bytes, expected: f444) else {
            return XCTFail("444 frame should parse")
        }
        XCTAssertEqual(frame.blockRecordCount, 1)
    }

    func testMaxPayloadWordsRecord() throws {
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 0xFFF)
        let frame = try XCTUnwrap(assertFrame(bytes))
        XCTAssertEqual(frame.records.last, 8..<8 + 0xFFF * 4)
    }

    func testParsesFromAMisalignedBuffer() throws {
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 4)
        var shifted = [UInt8](repeating: 0xEE, count: 1) + bytes
        shifted.withUnsafeMutableBytes { raw in
            let slice = UnsafeRawBufferPointer(rebasing: raw[1...])
            guard case .success(let frame) = Parser.parse(slice, expected: format) else {
                return XCTFail("misaligned base pointer should parse")
            }
            XCTAssertEqual(frame.blockRecordCount, 1)
        }
    }

    // MARK: Failures, one per case

    func testLengthPrefixedFramingIsDetected() {
        // A packet count of 3 (bit 31 clear) followed by a size, as the old framing does.
        assertFailure(word(0x0000_0003) + word(16) + [UInt8](repeating: 0, count: 16), .lengthPrefixedFraming)
    }

    func testBlockRecordFirstIsLengthPrefixedByTheFirstWordRule() {
        // A block record has bit 31 clear, so it is indistinguishable from a packet count.
        assertFailure(block(words: 4) + sequenceHeader(), .lengthPrefixedFraming)
    }

    func testNotWordAligned() {
        assertFailure(sequenceHeader() + [0, 0, 0], .notWordAligned)
    }

    func testEmptyAndTooShort() {
        assertFailure([], .missingSequenceHeader)
        assertFailure(word(0x8000_0000), .missingSequenceHeader)
    }

    func testOnlyPaddingHasNoSequenceHeader() {
        assertFailure(padding(words: 4), .missingSequenceHeader)
    }

    func testBlockAfterPaddingButBeforeSequenceHeader() {
        assertFailure(padding(words: 0) + block(words: 4) + sequenceHeader(), .missingSequenceHeader)
    }

    func testTruncatedTrailingWord() {
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 4) + word(0x1234)
        assertFailure(bytes, .truncatedRecord(offset: 8 + 16))
    }

    func testBlockRunsPastTheEnd() {
        var bytes = sequenceHeader(totalBlocks: 1) + block(words: 10)
        bytes.removeLast(4)
        assertFailure(bytes, .truncatedRecord(offset: 8))
    }

    func testSecondSequenceHeader() {
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 4) + sequenceHeader(totalBlocks: 1)
        assertFailure(bytes, .secondSequenceHeader(offset: 8 + 16))
    }

    func testUnknownSequenceCode() {
        // vibeshine never sends code 1 ("keep previous"); upstream does not decode it.
        assertFailure(sequenceHeader(code: 1), .unknownSequenceCode(1))
        assertFailure(sequenceHeader(code: 3), .unknownSequenceCode(3))
    }

    func testDimensionMismatch() {
        assertFailure(sequenceHeader(width: 1280, height: 720), .dimensionMismatch(width: 1280, height: 720))
        assertFailure(sequenceHeader(width: 1920, height: 1088), .dimensionMismatch(width: 1920, height: 1088))
    }

    func testChromaMismatch() {
        assertFailure(sequenceHeader(chroma444: true), .chromaMismatch)
        let f444 = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: true, bitDepth: 8)
        assertFailure(sequenceHeader(chroma444: false), .chromaMismatch, format: f444)
    }

    func testShortBlock() {
        for words in [0, 1] {
            var bytes = sequenceHeader(totalBlocks: 1) + block(words: 4)
            // Overwrite payload_words (bits 16..27 of w0, so byte 2 low nibble and byte 3).
            bytes[8 + 2] = UInt8(words)
            bytes[8 + 3] = 0
            assertFailure(bytes, .shortBlock(offset: 8))
        }
    }

    func testSequenceMismatch() {
        let bytes = sequenceHeader(sequence: 2, totalBlocks: 2)
            + block(words: 4, index: 0, sequence: 2)
            + block(words: 4, index: 1, sequence: 3)
        assertFailure(bytes, .sequenceMismatch(offset: 8 + 16))
    }

    func testPaddingOverrun() {
        var bytes = sequenceHeader(totalBlocks: 1) + block(words: 4)
        bytes += word(0xFFFF_FFFF) + word(3) + [UInt8](repeating: 0, count: 8)  // claims 12, has 8
        assertFailure(bytes, .paddingOverrun(offset: 8 + 16))
    }

    func testPaddingCountThatWouldOverflowIsRejected() {
        let bytes = sequenceHeader(totalBlocks: 0) + word(0xFFFF_FFFF) + word(0xFFFF_FFFF)
        assertFailure(bytes, .paddingOverrun(offset: 8))
    }

    // MARK: Why D6 must trim with lastPayloadLen

    func testTrailingZeroWordsFailAsShortBlock() {
        // The last RTP payload is zero-padded on the wire. Untrimmed, the zeros read as
        // a block record with payload_words = 0.
        let bytes = sequenceHeader(totalBlocks: 1) + block(words: 4) + [UInt8](repeating: 0, count: 8)
        assertFailure(bytes, .shortBlock(offset: 8 + 16))
    }

    // MARK: Coalescing

    func testCoalescedMergesTouchingRangesOnly() {
        let merged = Parser.coalesced([0..<8, 8..<24, 40..<48, 48..<60, 100..<104])
        XCTAssertEqual(merged, [0..<24, 40..<60, 100..<104])
        XCTAssertEqual(Parser.coalesced([]), [])
    }

    func testCoalescedRangesAvoidPadding() throws {
        let bytes = sequenceHeader(totalBlocks: 2) + block(words: 4) + padding(words: 1) + block(words: 4)
        let frame = try XCTUnwrap(assertFrame(bytes))
        let merged = Parser.coalesced(frame.records)
        XCTAssertEqual(merged, [0..<24, 36..<52])
        // No merged range may contain the padding magic as its first word.
        for range in merged {
            let first = bytes[range.lowerBound..<range.lowerBound + 4]
            XCTAssertNotEqual(Array(first), [0xFF, 0xFF, 0xFF, 0xFF])
        }
    }
}

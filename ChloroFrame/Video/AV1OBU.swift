//
//  AV1OBU.swift
//  ChloroFrame
//
//  Minimal, SETUP-ONLY AV1 OBU parsing. Used to extract and parse the sequence
//  header OBU once at decoder setup (and to answer the cheap key-frame fallback
//  predicate while awaiting an IDR). Never called on the steady-state frame path.
//
//  AV1 has no NAL units. A frame is a "temporal unit": a run of OBUs, each with a
//  1-2 byte header and (in the low-overhead bitstream Sunshine sends) a leb128
//  obu_size. Configuration lives in the sequence-header OBU (type 1), which av1C
//  needs verbatim plus a handful of parsed fields (profile/level/bitdepth/chroma/
//  dimensions). See design/av1-implementation-plan.md Steps 4-5.
//

import Foundation

// OBU types we care about (AV1 spec §6.2.2).
private let OBU_SEQUENCE_HEADER: UInt8 = 1
private let OBU_TEMPORAL_DELIMITER: UInt8 = 2
private let OBU_FRAME_HEADER: UInt8 = 3
private let OBU_TILE_GROUP: UInt8 = 4
private let OBU_FRAME: UInt8 = 6

/// Parsed fields from an AV1 sequence-header OBU, plus the raw OBU bytes for av1C.
struct AV1SequenceHeader {
    /// The COMPLETE sequence-header OBU as it appears in the bitstream:
    /// obu_header byte(s) + leb128 obu_size + payload. av1C `configOBUs` expects
    /// whole OBUs, so this is stored verbatim — header and size NOT stripped.
    let obuBytes: [UInt8]
    let seqProfile: UInt8          // 0=Main, 1=High, 2=Professional
    let seqLevelIdx0: UInt8        // operating point 0 level
    let seqTier0: UInt8
    let highBitdepth: Bool
    let twelveBit: Bool
    let monochrome: Bool
    let subsamplingX: Bool         // 1,1 = 4:2:0 (Main8/Main10)
    let subsamplingY: Bool
    let chromaSamplePosition: UInt8
    let maxWidth: Int              // max_frame_width_minus_1 + 1
    let maxHeight: Int             // max_frame_height_minus_1 + 1

    /// 8, 10, or 12. Derived per AV1 spec color_config().
    var bitDepth: Int {
        highBitdepth ? (twelveBit ? 12 : 10) : 8
    }
}

enum AV1OBU {

    // MARK: leb128

    /// Bounds-checked leb128 reader (AV1 spec §4.10.5). Advances `i` past the
    /// encoded value. Returns nil on truncation or an overlong (>8-byte) encoding.
    static func readLeb128(_ buf: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Int? {
        var value = 0
        for byteIndex in 0..<8 {
            guard i < buf.count else { return nil }
            let b = buf[i]; i += 1
            value |= Int(b & 0x7F) << (byteIndex * 7)
            if b & 0x80 == 0 { return value }
        }
        return nil  // more than 8 continuation bytes => invalid
    }

    // MARK: OBU walking

    /// One OBU located within a temporal unit.
    private struct OBU {
        let type: UInt8
        let obuStart: Int      // index of the obu_header (start of the whole OBU)
        let payloadStart: Int  // index of the first payload byte
        let payloadEnd: Int    // one past the last payload byte
        var wholeRange: Range<Int> { obuStart..<payloadEnd }
    }

    /// Parse a single OBU header (+ optional leb128 size) at `i`, returning the
    /// OBU descriptor and advancing `i` to the next OBU. Returns nil on malformed
    /// input or a missing size field (Sunshine sends obu_has_size_field=1).
    private static func readOBU(_ buf: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> OBU? {
        let obuStart = i
        guard i < buf.count else { return nil }
        let h = buf[i]; i += 1
        // obu_header: forbidden(1)=0, type(4), extension_flag(1), has_size_field(1), reserved(1)
        let type = (h >> 3) & 0x0F
        let extensionFlag = (h >> 2) & 0x01
        let hasSizeField  = (h >> 1) & 0x01
        if extensionFlag == 1 {
            guard i < buf.count else { return nil }  // skip obu_extension_header byte
            i += 1
        }
        guard hasSizeField == 1 else { return nil }
        guard let size = readLeb128(buf, &i) else { return nil }
        let payloadStart = i
        let payloadEnd = payloadStart + size
        guard payloadEnd <= buf.count else { return nil }
        i = payloadEnd
        return OBU(type: type, obuStart: obuStart, payloadStart: payloadStart, payloadEnd: payloadEnd)
    }

    /// Cheap key-frame fallback predicate (plan Step 3): does this temporal unit
    /// contain a sequence-header OBU before its first frame/tile OBU? Skips a
    /// leading temporal-delimiter OBU (Sunshine may emit one), so "leading" means
    /// "up front", not "byte 0". Does not fully parse the sequence header.
    static func hasLeadingSequenceHeader(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        while i < buf.count {
            guard let obu = readOBU(buf, &i) else { return false }
            switch obu.type {
            case OBU_SEQUENCE_HEADER:
                return true
            case OBU_TEMPORAL_DELIMITER:
                continue  // tolerate a leading TD and keep scanning
            case OBU_FRAME_HEADER, OBU_TILE_GROUP, OBU_FRAME:
                return false  // reached picture data without a seq header => not a key frame
            default:
                continue  // metadata/padding/etc — keep scanning
            }
        }
        return false
    }

    /// Length of the valid concatenated OBU stream from the start of `buf`,
    /// stopping at the first byte that isn't a valid sized OBU header. The
    /// reassembled temporal unit is zero-padded to a fixed shard size by FEC /
    /// packetization; VideoToolbox rejects that trailing padding with
    /// kVTVideoDecoderBadDataErr (-12911), so we trim to this length before submit.
    /// Safe because OBU size fields let us skip over payloads (which may contain
    /// zeros) and only inspect actual OBU boundaries — padding starts where the
    /// next "OBU" has no size field (e.g. a 0x00 byte).
    static func validTemporalUnitLength(_ buf: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0
        var lastGoodEnd = 0
        while i < buf.count {
            guard let obu = readOBU(buf, &i) else { break }
            // Valid OBU types are 1...8 and 15 (padding). Anything else (notably
            // type 0 reserved, i.e. a zero byte) marks the start of trailing padding.
            guard (obu.type >= 1 && obu.type <= 8) || obu.type == 15 else { break }
            lastGoodEnd = obu.payloadEnd
        }
        return lastGoodEnd
    }

    /// Walk OBUs and fully parse the first sequence-header OBU (type 1). Tolerates
    /// a leading temporal-delimiter or other non-frame OBUs. Returns nil if no
    /// sequence header is found or the bitstream is malformed/truncated.
    static func parseSequenceHeader(in buf: UnsafeBufferPointer<UInt8>) -> AV1SequenceHeader? {
        var i = 0
        while i < buf.count {
            guard let obu = readOBU(buf, &i) else { return nil }
            if obu.type == OBU_SEQUENCE_HEADER {
                let payload = UnsafeBufferPointer(rebasing: buf[obu.payloadStart..<obu.payloadEnd])
                guard let fields = parseSeqHeaderPayload(payload) else { return nil }
                let obuBytes = Array(UnsafeBufferPointer(rebasing: buf[obu.wholeRange]))
                return fields.withOBUBytes(obuBytes)
            }
            // Stop once we hit picture data without having seen a sequence header.
            if obu.type == OBU_FRAME_HEADER || obu.type == OBU_TILE_GROUP || obu.type == OBU_FRAME {
                return nil
            }
        }
        return nil
    }

    // MARK: Sequence-header bit parsing (AV1 spec §5.5)

    /// Intermediate parsed fields, assembled before the raw OBU bytes are known.
    private struct SeqFields {
        var seqProfile: UInt8 = 0
        var seqLevelIdx0: UInt8 = 0
        var seqTier0: UInt8 = 0
        var highBitdepth = false
        var twelveBit = false
        var monochrome = false
        var subsamplingX = true
        var subsamplingY = true
        var chromaSamplePosition: UInt8 = 0
        var maxWidth = 0
        var maxHeight = 0

        var bitDepth: Int { highBitdepth ? (twelveBit ? 12 : 10) : 8 }

        func withOBUBytes(_ bytes: [UInt8]) -> AV1SequenceHeader {
            AV1SequenceHeader(
                obuBytes: bytes, seqProfile: seqProfile, seqLevelIdx0: seqLevelIdx0,
                seqTier0: seqTier0, highBitdepth: highBitdepth, twelveBit: twelveBit,
                monochrome: monochrome, subsamplingX: subsamplingX, subsamplingY: subsamplingY,
                chromaSamplePosition: chromaSamplePosition, maxWidth: maxWidth, maxHeight: maxHeight)
        }
    }

    /// MSB-first bit reader over a borrowed byte view. All reads are bounds-checked;
    /// once exhausted, `ok` goes false and further reads return 0 so the parser bails.
    private struct BitReader {
        let buf: UnsafeBufferPointer<UInt8>
        var bitPos = 0
        var ok = true

        init(_ buf: UnsafeBufferPointer<UInt8>) { self.buf = buf }

        mutating func bit() -> UInt32 {
            let byteIndex = bitPos >> 3
            guard byteIndex < buf.count else { ok = false; return 0 }
            let shift = 7 - (bitPos & 7)
            bitPos += 1
            return UInt32((buf[byteIndex] >> shift) & 1)
        }

        mutating func bits(_ n: Int) -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<n { v = (v << 1) | bit() }
            return v
        }
    }

    /// Parse the bits of a sequence_header_obu() payload we need. Walks the
    /// structure in order (fields are not at fixed offsets); the variable-length
    /// operating-points loop and optional timing/decoder-model blocks must be
    /// consumed, not seeked. Returns nil if the reader runs out of bits.
    private static func parseSeqHeaderPayload(_ payload: UnsafeBufferPointer<UInt8>) -> SeqFields? {
        var r = BitReader(payload)
        var f = SeqFields()

        f.seqProfile = UInt8(r.bits(3))
        _ = r.bit()                                   // still_picture
        let reducedStillPicture = r.bit()             // reduced_still_picture_header

        var decoderModelInfoPresent = false
        var bufferDelayLengthMinus1: UInt32 = 0
        var operatingPointsCntMinus1: UInt32 = 0

        if reducedStillPicture == 1 {
            f.seqLevelIdx0 = UInt8(r.bits(5))
            f.seqTier0 = 0
        } else {
            let timingInfoPresent = r.bit()
            if timingInfoPresent == 1 {
                // timing_info()
                _ = r.bits(32)                        // num_units_in_display_tick
                _ = r.bits(32)                        // time_scale
                let equalPictureInterval = r.bit()
                if equalPictureInterval == 1 {
                    _ = readUvlc(&r)                  // num_ticks_per_picture_minus_1
                }
                let decoderModelInfoPresentFlag = r.bit()
                if decoderModelInfoPresentFlag == 1 {
                    decoderModelInfoPresent = true
                    bufferDelayLengthMinus1 = r.bits(5)
                    _ = r.bits(32)                    // num_units_in_decoding_tick
                    _ = r.bits(5)                     // buffer_removal_time_length_minus_1
                    _ = r.bits(5)                     // frame_presentation_time_length_minus_1
                }
            }
            let initialDisplayDelayPresent = r.bit()
            operatingPointsCntMinus1 = r.bits(5)
            for opIndex in 0...Int(operatingPointsCntMinus1) {
                _ = r.bits(12)                        // operating_point_idc[i]
                let levelIdx = r.bits(5)              // seq_level_idx[i]
                var tier: UInt32 = 0
                if levelIdx > 7 {
                    tier = r.bit()                    // seq_tier[i]
                }
                if decoderModelInfoPresent {
                    let decoderModelPresentForThisOp = r.bit()
                    if decoderModelPresentForThisOp == 1 {
                        let n = Int(bufferDelayLengthMinus1) + 1
                        _ = r.bits(n)                 // decoder_buffer_delay
                        _ = r.bits(n)                 // encoder_buffer_delay
                        _ = r.bit()                   // low_delay_mode_flag
                    }
                }
                if initialDisplayDelayPresent == 1 {
                    let initialDisplayDelayPresentForThisOp = r.bit()
                    if initialDisplayDelayPresentForThisOp == 1 {
                        _ = r.bits(4)                 // initial_display_delay_minus_1
                    }
                }
                if opIndex == 0 {
                    f.seqLevelIdx0 = UInt8(levelIdx)
                    f.seqTier0 = UInt8(tier)
                }
            }
        }

        let frameWidthBitsMinus1 = Int(r.bits(4))
        let frameHeightBitsMinus1 = Int(r.bits(4))
        let maxFrameWidthMinus1 = r.bits(frameWidthBitsMinus1 + 1)
        let maxFrameHeightMinus1 = r.bits(frameHeightBitsMinus1 + 1)
        f.maxWidth = Int(maxFrameWidthMinus1) + 1
        f.maxHeight = Int(maxFrameHeightMinus1) + 1

        var frameIdNumbersPresent: UInt32 = 0
        if reducedStillPicture == 0 {
            frameIdNumbersPresent = r.bit()
        }
        if frameIdNumbersPresent == 1 {
            _ = r.bits(4)                             // delta_frame_id_length_minus_2
            _ = r.bits(3)                             // additional_frame_id_length_minus_1
        }

        _ = r.bit()                                   // use_128x128_superblock
        _ = r.bit()                                   // enable_filter_intra
        _ = r.bit()                                   // enable_intra_edge_filter

        if reducedStillPicture == 0 {
            _ = r.bit()                               // enable_interintra_compound
            _ = r.bit()                               // enable_masked_compound
            _ = r.bit()                               // enable_warped_motion
            _ = r.bit()                               // enable_dual_filter
            let enableOrderHint = r.bit()
            if enableOrderHint == 1 {
                _ = r.bit()                           // enable_jnt_comp
                _ = r.bit()                           // enable_ref_frame_mvs
            }
            let seqChooseScreenContentTools = r.bit()
            var seqForceScreenContentTools: UInt32 = 2 // SELECT_SCREEN_CONTENT_TOOLS
            if seqChooseScreenContentTools == 0 {
                seqForceScreenContentTools = r.bit()
            }
            if seqForceScreenContentTools > 0 {
                let seqChooseIntegerMv = r.bit()
                if seqChooseIntegerMv == 0 {
                    _ = r.bit()                       // seq_force_integer_mv
                }
            }
            if enableOrderHint == 1 {
                _ = r.bits(3)                         // order_hint_bits_minus_1
            }
        }

        _ = r.bit()                                   // enable_superres
        _ = r.bit()                                   // enable_cdef
        _ = r.bit()                                   // enable_restoration

        // color_config()
        let highBitdepth = r.bit()
        f.highBitdepth = highBitdepth == 1
        if f.seqProfile == 2 && f.highBitdepth {
            f.twelveBit = r.bit() == 1
        }
        if f.seqProfile == 1 {
            f.monochrome = false
        } else {
            f.monochrome = r.bit() == 1
        }
        let colorDescriptionPresent = r.bit()
        var colorPrimaries: UInt32 = 2   // CP_UNSPECIFIED
        var transferCharacteristics: UInt32 = 2
        var matrixCoefficients: UInt32 = 2
        if colorDescriptionPresent == 1 {
            colorPrimaries = r.bits(8)
            transferCharacteristics = r.bits(8)
            matrixCoefficients = r.bits(8)
        }
        if f.monochrome {
            _ = r.bit()                               // color_range
            f.subsamplingX = true
            f.subsamplingY = true
            f.chromaSamplePosition = 0
        } else if colorPrimaries == 1 && transferCharacteristics == 13 && matrixCoefficients == 0 {
            // sRGB
            f.subsamplingX = false
            f.subsamplingY = false
        } else {
            _ = r.bit()                               // color_range
            if f.seqProfile == 0 {
                f.subsamplingX = true; f.subsamplingY = true
            } else if f.seqProfile == 1 {
                f.subsamplingX = false; f.subsamplingY = false
            } else {
                if f.bitDepth == 12 {
                    f.subsamplingX = r.bit() == 1
                    f.subsamplingY = f.subsamplingX ? (r.bit() == 1) : false
                } else {
                    f.subsamplingX = true
                    f.subsamplingY = false
                }
            }
            if f.subsamplingX && f.subsamplingY {
                f.chromaSamplePosition = UInt8(r.bits(2))
            }
        }

        guard r.ok else { return nil }
        return f
    }

    /// uvlc() reader (AV1 spec §4.10.3), used inside timing_info().
    private static func readUvlc(_ r: inout BitReader) -> UInt32 {
        var leadingZeros = 0
        while true {
            let done = r.bit()
            if !r.ok { return 0 }
            if done == 1 { break }
            leadingZeros += 1
            if leadingZeros >= 32 { return UInt32.max }
        }
        let value = r.bits(leadingZeros)
        return value + (UInt32(1) << leadingZeros) - 1
    }
}

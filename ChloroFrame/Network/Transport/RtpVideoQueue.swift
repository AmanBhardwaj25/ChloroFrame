//
//  RtpVideoQueue.swift
//  ChloroFrame
//
//  Swift translation of RtpVideoQueue.c from moonlight-common-c.
//
//  Handles:
//   - Per-FEC-block state machine (frame/block transitions, duplicate rejection)
//   - Packet ordering by streamPacketIndex / RTP sequence number
//   - Reed-Solomon recovery via ReedSolomonCoder when data shards are missing
//   - Multi-FEC block frames (large IDR frames split across ≥2 FEC blocks)
//
//  Call addPacket(_:) for every incoming UDP datagram.
//  Recovered/sorted data packet payloads arrive via onVideoPacket.

import Foundation
import QuartzCore

// ─── Packet layout constants ──────────────────────────────────────────────────
// Apollo always uses FLAG_EXTENSION, so the RTP header is always:
//   12-byte RTP base + 4-byte extension = 16 bytes
// Followed immediately by NV_VIDEO_PACKET (16 bytes, LE fields).
// SOF+FEC-block-0 packets carry a per-frame metadata header after NV_VIDEO_PACKET (size varies: see kFrameHeaderSize* constants).

private let kRtpHeaderSize    = 16
private let kNvPacketSize     = 16
// Frame header size on SOF+FEC-block-0 packets is determined by the first byte of the SOF payload.
// 0x01 → 8 bytes (all server versions from 5.x onward).
// 0x81 → extended header: 24 B on Sunshine ≥7.1.415, 41 B ≥7.1.446, 44 B ≥7.1.450.
// TODO: gate the 0x81 size on negotiated server version once RTSPClient exposes it.
// Proof: VideoDepacketizer.c:914-965 in moonlight-common-c.
private let kFrameHeaderSizeStandard: Int  =  8   // first byte 0x01
private let kFrameHeaderSizeExtended: Int  = 44   // first byte 0x81, targeting Sunshine ≥7.1.450

// NV_VIDEO_PACKET flags
private let kFlagSOF: UInt8 = 0x04
private let kFlagEOF: UInt8 = 0x02
private let kFlagPIC: UInt8 = 0x01
// NV_VIDEO_PACKET.extraFlags (header byte +9): the payload starts with a PyroWave record.
private let kExtraFlagRecordStart: UInt8 = 0x80

// ─── Frame metadata ───────────────────────────────────────────────────────────

/// Per-frame facts read from the 8-byte short frame header on the SOF packet of FEC block 0.
/// H.264, HEVC and AV1 read only `frameType`; the other fields exist for PyroWave.
nonisolated struct FrameMeta: Equatable {
    /// Header byte 3: 1=P, 2=IDR, 4=intra-refresh, 5=P-ref-inval. 1 when no header was present.
    var frameType: UInt8 = 1
    /// Header bytes 4-5 (LE16): payload bytes that are real data in the last data packet
    /// (the rest is zero padding). 0 when unknown (no header, or the extended 0x81 header).
    var lastPayloadLen: Int = 0
    /// Header bytes 6-7 (LE16): number of leading packets that carry the PyroWave critical
    /// (coarsest) data, 0 when unknown. Used by partial-frame recovery (D10).
    var pyroWaveCriticalPackets: Int = 0
    /// Set only for a PyroWave frame that is being delivered with zero-filled holes (D10).
    /// nil for every complete frame and for every other codec.
    var lossMap: PyroWaveLossMap? = nil

    /// Parses the frame header whose first byte is at `headerOffset` in `slot`. Every read is
    /// bounds-checked. Only the standard 8-byte header (any first byte but 0x81) carries
    /// `lastPayloadLen` and the critical packet count; for the extended 0x81 header those stay 0.
    static func parseShortHeader(_ slot: [UInt8], headerOffset: Int) -> FrameMeta {
        var meta = FrameMeta()
        let firstByte: UInt8 = headerOffset < slot.count ? slot[headerOffset] : 0x01
        let typeOffset = headerOffset + 3
        meta.frameType = typeOffset < slot.count ? slot[typeOffset] : 1
        if firstByte != 0x81, headerOffset + 7 < slot.count {
            meta.lastPayloadLen = Int(slot[headerOffset + 4]) | Int(slot[headerOffset + 5]) << 8
            meta.pyroWaveCriticalPackets = Int(slot[headerOffset + 6]) | Int(slot[headerOffset + 7]) << 8
        }
        return meta
    }
}

// ─── Add-result ───────────────────────────────────────────────────────────────

enum RtpvAddResult {
    case rejected
    case queued
}

// ─── Queue ─────────────────────────────────────────────────────────────────────

final class RtpVideoQueue {

    // Configuration (set once at init).
    let packetSize: Int      // Bytes after RTP header: NV_VIDEO_PACKET + compressed payload.
    let blockSize: Int       // = packetSize + kRtpHeaderSize (full datagram size for RS FEC).
    let useSwiftFEC: Bool
    /// PyroWave only (D10): deliver a frame whose blocks lost non-critical packets, with the
    /// holes zero-filled and described by `FrameMeta.lossMap`. False keeps the whole-frame
    /// behavior of every other codec.
    let partialDelivery: Bool

    /// Monotonic seconds. Injectable so tests can step time.
    var clock: () -> Double = { CACurrentMediaTime() }

    /// How long the final block of a frame must be silent, after its last data packet arrived,
    /// before it is delivered without waiting for the next frame (protocol doc, "Partial frames").
    static let silenceDeadlineSeconds = 0.001

    // Emitted once per fully assembled frame with a borrowed view of the complete
    // elementary byte stream (all blocks, in sequence order).
    // Parameters: (frameIndex, frameBytes, rtpTimestamp, meta)
    // rtpTimestamp is the RTP timestamp of the frame (90 kHz clock, big-endian bytes 4-7 of RTP header).
    // meta.frameType is the Sunshine frame-header type byte (1=P, 2=IDR, 4=intra-refresh,
    // 5=P-ref-inval; 1 when no header was present). H.264/HEVC ignore it; AV1 uses it.
    // meta.lastPayloadLen and meta.pyroWaveCriticalPackets are for PyroWave (see FrameMeta).
    // The pointer is only valid for the duration of the call — copy if it must outlive it.
    var onFrameAssembled: ((UInt32, UnsafeBufferPointer<UInt8>, UInt32, FrameMeta) -> Void)?

    // Fired when a frame is determined to be unrecoverable (lost FEC block or frame gap).
    // The receiver should discard P-frames and request an IDR from the server.
    var onFrameLost: ((UInt32) -> Void)?

    // Optional stats collector — set by RTPVideoReceiver after init.
    var stats: StreamStatsCollector?

    // ── Per-FEC-block state ───────────────────────────────────────────────────

    private(set) var currentFrameNumber: UInt32 = 1

    private var multiFecCurrentBlock: UInt8 = 0
    private var multiFecLastBlock:    UInt8 = 0

    private var bufferLowest:      UInt16 = 0   // lowest RTP seqNum in this FEC block
    private var bufferFirstParity: UInt16 = 0   // first parity RTP seqNum
    private var bufferHighest:     UInt16 = 0   // highest valid RTP seqNum

    private var bufferDataShards:   Int = 0
    private var bufferParityShards: Int = 0
    private var fecPercentage:      Int = 0

    private var rxData:    Int    = 0   // received data shard count
    private var rxParity:  Int    = 0   // received parity shard count
    private var rxHighest: UInt16 = 0   // highest received RTP seqNum
    private var missing:   Int    = 0   // inferred missing shards so far

    // ── Slot storage — preallocated, reused across blocks (no per-packet allocation) ──
    // Shard i of the current FEC block lives in slotData[i]: full packet bytes,
    // zero-padded to blockSize (rows are constant-size per session, allocated once
    // and grown only when a block has more shards than any previous block).
    private var slotData:   [[UInt8]] = []
    private var slotUsed:   [Bool]    = []
    private var slotLength: [Int]     = []   // received length before padding (blockSize if recovered)
    private var slotFlags:  [UInt8]   = []   // NV_VIDEO_PACKET flags byte
    // True once any packet of the current block has been stored; replaces the old
    // pending.isEmpty test in block-change detection.
    private var havePacketsInBlock = false

    // Whole-frame Annex-B assembly buffer, accumulated across FEC blocks and
    // reused frame to frame (capacity retained).
    private var frameAssembly: [UInt8] = []
    private var frameAssemblyPackets = 0

    // RS codec instance for the current FEC block.
    private var rsCodec: ReedSolomonCoder?

    // Set when onFrameLost has been fired for currentFrameNumber; cleared on initBlock().
    private var reportedLostFrame = false

    // RTP timestamp (90 kHz, BE bytes 4-7) of the current frame; set on the first FEC block.
    private var currentFrameRtpTimestamp: UInt32 = 0

    // Sunshine frame-header type byte (offset +3 of the SOF frame header): 1=P,
    // 2=IDR, 4=intra-refresh, 5=P-ref-inval. Defaults to 1 (P) when no header is
    // present. Read in stageBlock when the SOF header is parsed, emitted in submitFrame.
    private var currentFrameType: UInt8 = 1
    // Short-header fields beyond frameType (PyroWave). Reset together with currentFrameType.
    private var currentLastPayloadLen = 0
    private var currentCriticalPackets = 0
    // PyroWave partial delivery: the frame's first packet used the 8-byte short header and was
    // flagged as starting with a record. Set when block 0's first packet is staged.
    private var currentFrameFlagsUsable = false

    // Partial delivery (PyroWave only). One entry per staged data payload of the current
    // frame, in frame order: byte offset in `frameAssembly`, lost, record-start flag.
    private var payloadStarts: [Int] = []
    private var payloadLost: [Bool] = []
    private var payloadRecordStart: [Bool] = []
    private var payloadLostCount = 0
    /// When the silence deadline expires (`clock()` seconds), or nil when none is armed.
    private(set) var pendingDeadline: Double?
    // The last frame delivered with holes, so packets that arrive for it afterwards can be
    // counted and timed (diagnostics only).
    private var lastPartialFrame: UInt32?
    private var lastPartialDeliveredAt = 0.0

    private var packetLogCount = 0
    private var blockLogCount = 0
    private var frameLogCount = 0
    private var fecLogCount = 0
    private var rejectLogCount = 0

    init(packetSize: Int = 1392, useSwiftFEC: Bool = false, partialDelivery: Bool = false) {
        self.packetSize = packetSize
        self.partialDelivery = partialDelivery
        // Moonlight sizes each RS row as StreamConfig.packetSize + MAX_RTP_HEADER_SIZE.
        // StreamConfig.packetSize already includes NV_VIDEO_PACKET.
        self.blockSize  = packetSize + kRtpHeaderSize
        self.useSwiftFEC = useSwiftFEC
        StreamLog.log("[rtp/queue] queue init packetSize=\(packetSize) rtpHeader=\(kRtpHeaderSize) nvHeader=\(kNvPacketSize) rowBytes=\(blockSize) swiftFEC=\(useSwiftFEC)")
    }

    // MARK: - Public

    /// Add one received UDP datagram. The buffer is borrowed — bytes are copied into
    /// reusable slot storage before returning, so the caller may reuse its receive buffer.
    @discardableResult
    func addPacket(_ datagram: UnsafeRawBufferPointer) -> RtpvAddResult {
        guard datagram.count >= kRtpHeaderSize + kNvPacketSize else {
            return reject("short datagram len=\(datagram.count)")
        }

        // ── Parse RTP header ────────────────────────────────────────────────
        let seqNum = UInt16(datagram[2]) << 8 | UInt16(datagram[3])

        // ── Parse NV_VIDEO_PACKET (all multi-byte fields are LE) ────────────
        let nb = kRtpHeaderSize   // NV_VIDEO_PACKET base offset
        let frameIndex = le32(datagram, nb + 4)
        let flags      = datagram[nb + 8]
        let multiFecBlocks = datagram[nb + 11]
        let fecInfo    = le32(datagram, nb + 12)

        // fecInfo bit layout:
        //   [31:22]  total data shards in this FEC block  (10 bits)
        //   [21:12]  this packet's index within the block (10 bits)
        //   [11: 4]  FEC percentage                       ( 8 bits)
        let fecIndex  = Int((fecInfo >> 12) & 0x3FF)
        let fecBlock  = (multiFecBlocks >> 4) & 0x3  // current FEC block number
        let fecLast   = (multiFecBlocks >> 6) & 0x3  // last FEC block number

        if packetLogCount < 8 {
            let dataShards = Int((fecInfo >> 22) & 0x3FF)
            let fecPct = Int((fecInfo >> 4) & 0xFF)
            StreamLog.log("[rtp/queue] rx len=\(datagram.count) seq=\(seqNum) frame=\(frameIndex) flags=\(flagString(flags)) fecIndex=\(fecIndex) block=\(fecBlock)/\(fecLast) dataShards=\(dataShards) fecPct=\(fecPct) rowBytes=\(blockSize)")
            packetLogCount += 1
        }

        // Reject frames that are behind our current position.
        guard frameIndex >= currentFrameNumber else {
            if partialDelivery, frameIndex == lastPartialFrame {
                stats?.recordLatePacket(ms: (clock() - lastPartialDeliveredAt) * 1000)
            }
            return reject("old frame frame=\(frameIndex) current=\(currentFrameNumber) seq=\(seqNum)")
        }

        // Reject FEC blocks behind our current block within the same frame.
        if frameIndex == currentFrameNumber && fecBlock < multiFecCurrentBlock {
            return reject("old fec block frame=\(frameIndex) block=\(fecBlock) currentBlock=\(multiFecCurrentBlock)")
        }

        // ── Detect whether this packet starts a new FEC block ───────────────
        let blockChanged = !havePacketsInBlock
            || frameIndex != currentFrameNumber
            || fecBlock   != multiFecCurrentBlock

        if blockChanged {
            if havePacketsInBlock {
                // We were in the middle of a block when a new one arrived.
                if frameIndex != currentFrameNumber {
                    // Frame changed. PyroWave delivers the final block with its holes zero filled
                    // when the rules allow; every other case is an unrecoverable frame.
                    if partialDelivery, multiFecCurrentBlock == multiFecLastBlock, deliverPartialFrame(byDeadline: false) {
                        // Delivered; deliverPartialFrame advanced the frame state.
                    } else {
                        if partialDelivery {
                            // A later block that never started is a whole missing block.
                            notePartialDrop(multiFecCurrentBlock != multiFecLastBlock
                                            ? .wholeBlock : (partialBlocker() ?? .ineligible))
                        }
                        if !reportedLostFrame {
                            onFrameLost?(currentFrameNumber)
                            stats?.recordFrameLost()
                            reportedLostFrame = true
                        }
                        purge()
                        clearFrameAssembly()
                    }
                } else if partialDelivery, fecBlock == multiFecCurrentBlock &+ 1, stageIncompleteBlock() {
                    // The next block of the same frame started: the current one is staged with
                    // zeros where packets are missing, and the frame carries on.
                    clearBlockSlots()
                    rsCodec = nil
                    multiFecCurrentBlock = fecBlock
                } else {
                    // Same frame, different FEC block — we missed a block; can't recover.
                    if partialDelivery {
                        notePartialDrop(fecBlock == multiFecCurrentBlock &+ 1
                                        ? (partialBlocker() ?? .ineligible) : .wholeBlock)
                    }
                    if !reportedLostFrame {
                        onFrameLost?(currentFrameNumber)
                        stats?.recordFrameLost()
                        reportedLostFrame = true
                    }
                    purge()
                    currentFrameNumber = frameIndex &+ 1
                    multiFecCurrentBlock = 0
                    clearFrameAssembly()
                    return reject("missed fec block frame=\(frameIndex) block=\(fecBlock) currentBlock=\(multiFecCurrentBlock)")
                }
            } else if frameIndex != currentFrameNumber {
                // Old frame ended cleanly but we skipped some frames. A PyroWave frame that was
                // abandoned between blocks (a whole block never arrived) is a lost frame.
                if partialDelivery, frameAssemblyPackets > 0 {
                    notePartialDrop(.wholeBlock)
                    onFrameLost?(currentFrameNumber)
                    stats?.recordFrameLost()
                }
                clearFrameAssembly()
            }

            if partialDelivery {
                // The frame must start at block 0 and continue block by block. Anything else means
                // a whole FEC block (its size unknown) never arrived: the frame cannot be staged.
                let expectedBlock: UInt8 = frameIndex == currentFrameNumber && frameAssemblyPackets > 0
                    ? multiFecCurrentBlock : 0
                if fecBlock != expectedBlock {
                    notePartialDrop(expectedBlock == 0 ? .firstPacket : .wholeBlock)
                    if !(frameIndex == currentFrameNumber && reportedLostFrame) {
                        onFrameLost?(frameIndex)
                        stats?.recordFrameLost()
                    }
                    purge()
                    clearFrameAssembly()
                    currentFrameNumber = frameIndex &+ 1
                    multiFecCurrentBlock = 0
                    return reject("whole fec block missing frame=\(frameIndex) block=\(fecBlock) expected=\(expectedBlock)")
                }
            }

            initBlock(seqNum: seqNum, frameIndex: frameIndex,
                      fecIndex: fecIndex, fecInfo: fecInfo,
                      fecBlock: fecBlock, fecLast: fecLast)

            // Capture the RTP timestamp (90 kHz, BE bytes 4-7) on the first FEC block of each frame.
            // All packets in a frame share the same RTP timestamp, so we only need one.
            if fecBlock == 0 {
                currentFrameRtpTimestamp = UInt32(datagram[4]) << 24 | UInt32(datagram[5]) << 16
                                         | UInt32(datagram[6]) << 8  | UInt32(datagram[7])
                // Default to P-frame; stageBlock overwrites from the SOF header when
                // present, so a frame whose header is unavailable can't inherit a
                // stale (e.g. IDR) type from the previous frame.
                currentFrameType = 1
                currentLastPayloadLen = 0
                currentCriticalPackets = 0
                currentFrameFlagsUsable = false
            }
        }

        // Reject packets above the valid range for this block.
        if isBefore16(bufferHighest, seqNum) {
            return reject("seq above block range seq=\(seqNum) highest=\(bufferHighest) frame=\(frameIndex)")
        }

        // Compute 0-based index within FEC block.
        let idx = Int(seqNum &- bufferLowest)
        let total = bufferDataShards + bufferParityShards

        // A stale seqNum below bufferLowest wraps to a huge idx — reject it before
        // it can touch slot storage or the missing-packet accounting.
        guard idx < total else {
            return reject("seq below block range seq=\(seqNum) lowest=\(bufferLowest) frame=\(frameIndex)")
        }

        // Reject duplicate.
        if slotUsed[idx] {
            return reject("duplicate seq=\(seqNum) idx=\(idx) frame=\(frameIndex)")
        }

        // ── Store the packet (copy into the reusable slot row, zero-pad to blockSize) ──
        let copyLen = min(datagram.count, blockSize)
        slotData[idx].withUnsafeMutableBytes { dest in
            memcpy(dest.baseAddress!, datagram.baseAddress!, copyLen)
            if copyLen < blockSize {
                memset(dest.baseAddress! + copyLen, 0, blockSize - copyLen)
            }
        }
        slotUsed[idx]   = true
        slotLength[idx] = datagram.count
        slotFlags[idx]  = flags

        let isParity = !isBefore16(seqNum, bufferFirstParity)

        // Update missing-packet tracking.
        if !havePacketsInBlock {
            missing   += Int(seqNum &- bufferLowest)
            rxHighest  = seqNum
        } else if isBefore16(rxHighest, seqNum) {
            missing   += Int(seqNum &- rxHighest) - 1
            rxHighest  = seqNum
        } else {
            missing    = max(0, missing - 1)
        }
        havePacketsInBlock = true

        if isParity { rxParity += 1 } else { rxData += 1 }

        // ── Try to reconstruct this FEC block ───────────────────────────────
        guard tryReconstruct() else {
            armSilenceDeadlineIfEligible()
            return .queued
        }
        pendingDeadline = nil

        // FEC block complete — append its data payloads to the frame assembly.
        stageBlock()

        if multiFecCurrentBlock < multiFecLastBlock {
            // More FEC blocks to go for this frame; advance block counter.
            multiFecCurrentBlock += 1
            clearBlockSlots()
            rsCodec = nil
        } else {
            // Last FEC block done — submit the entire frame.
            submitFrame()
            currentFrameNumber  += 1
            multiFecCurrentBlock = 0
            clearFrameAssembly()
            clearBlockSlots()
            rsCodec = nil
        }

        return .queued
    }

    // MARK: - Private: block lifecycle

    private func initBlock(seqNum: UInt16, frameIndex: UInt32,
                           fecIndex: Int, fecInfo: UInt32,
                           fecBlock: UInt8, fecLast: UInt8) {
        currentFrameNumber   = frameIndex
        multiFecCurrentBlock = fecBlock
        multiFecLastBlock    = fecLast
        reportedLostFrame    = false
        pendingDeadline      = nil

        bufferDataShards   = Int((fecInfo >> 22) & 0x3FF)
        fecPercentage      = Int((fecInfo >>  4) & 0xFF)
        bufferParityShards = (bufferDataShards * fecPercentage + 99) / 100

        bufferLowest      = seqNum &- UInt16(fecIndex)
        bufferFirstParity = bufferLowest &+ UInt16(bufferDataShards)
        // Last valid seqNum = bufferLowest + total - 1 (works whether parity is 0 or not).
        bufferHighest     = bufferLowest &+ UInt16(bufferDataShards + bufferParityShards) &- 1

        rxData    = 0; rxParity  = 0
        rxHighest = 0; missing   = 0

        // Grow slot storage if this block has more shards than any previous one;
        // existing rows (blockSize each) are reused without reallocation.
        let total = bufferDataShards + bufferParityShards
        while slotData.count < total {
            slotData.append([UInt8](repeating: 0, count: blockSize))
            slotUsed.append(false)
            slotLength.append(0)
            slotFlags.append(0)
        }
        clearBlockSlots()

        rsCodec = bufferParityShards > 0
            ? makeReedSolomon(dataShards: bufferDataShards,
                              parityShards: bufferParityShards,
                              useSwift: useSwiftFEC)
            : nil

        if blockLogCount < 12 {
            StreamLog.log("[rtp/queue] block start frame=\(frameIndex) block=\(fecBlock)/\(fecLast) seqBase=\(bufferLowest) seqHigh=\(bufferHighest) data=\(bufferDataShards) parity=\(bufferParityShards) fecPct=\(fecPercentage)")
            blockLogCount += 1
        }
    }

    private func purge() {
        clearBlockSlots()
        rsCodec = nil
        pendingDeadline = nil
    }

    /// Mark all slots free for the next block (row buffers are retained and reused).
    private func clearBlockSlots() {
        for i in slotUsed.indices { slotUsed[i] = false }
        havePacketsInBlock = false
    }

    private func clearFrameAssembly() {
        frameAssembly.removeAll(keepingCapacity: true)
        frameAssemblyPackets = 0
        if partialDelivery {
            payloadStarts.removeAll(keepingCapacity: true)
            payloadLost.removeAll(keepingCapacity: true)
            payloadRecordStart.removeAll(keepingCapacity: true)
            payloadLostCount = 0
        }
    }

    // MARK: - Private: reconstruction

    private func tryReconstruct() -> Bool {
        // Need at least bufferDataShards packets (any mix of data + parity) to recover.
        guard rxData + rxParity >= bufferDataShards else { return false }

        // Already have all data — no FEC needed.
        if rxData == bufferDataShards {
            logFec("complete without recovery frame=\(currentFrameNumber) block=\(multiFecCurrentBlock) data=\(rxData)/\(bufferDataShards)")
            return true
        }

        // Attempt FEC recovery.
        guard let rs = rsCodec, bufferParityShards > 0 else {
            logFec("waiting/no fec frame=\(currentFrameNumber) block=\(multiFecCurrentBlock) data=\(rxData)/\(bufferDataShards) parity=\(rxParity)/\(bufferParityShards) missing=\(missing)")
            return false
        }

        // Build the RS matrix only on this (rare) recovery path. Present rows are
        // CoW references to slot storage — no bytes are copied until the RS decoder
        // mutates a row; missing rows start zeroed and are filled by decode.
        let total = bufferDataShards + bufferParityShards
        var shards = [[UInt8]](repeating: [UInt8](repeating: 0, count: blockSize), count: total)
        var marks  = [Bool](repeating: true, count: total)

        for i in 0..<total where slotUsed[i] {
            shards[i] = slotData[i]
            marks[i]  = false
        }

        guard rs.decode(shards: &shards, marks: marks, blockSize: blockSize) else {
            logFec("recovery failed frame=\(currentFrameNumber) block=\(multiFecCurrentBlock) data=\(rxData)/\(bufferDataShards) parity=\(rxParity)/\(bufferParityShards) missing=\(missing)")
            return false
        }

        // Install recovered data shards back into slot storage.
        var recoveredCount = 0
        for i in 0..<bufferDataShards where marks[i] {
            let nb = kRtpHeaderSize
            guard shards[i].count > nb + kNvPacketSize else { continue }
            let recovFlags = shards[i][nb + 8]

            // Sanity-check the recovered packet's flags.
            let isSof = i == 0
            let isEof = i == bufferDataShards - 1
            if  isSof && recovFlags & kFlagSOF == 0 { continue }
            if  isEof && recovFlags & kFlagEOF == 0 { continue }
            if !isSof && !isEof && recovFlags & kFlagPIC == 0 { continue }

            slotData[i]   = shards[i]
            slotUsed[i]   = true
            slotLength[i] = blockSize
            slotFlags[i]  = recovFlags
            recoveredCount += 1
        }
        if recoveredCount > 0 { stats?.recordPacketsRecovered(recoveredCount) }

        logFec("recovery OK frame=\(currentFrameNumber) block=\(multiFecCurrentBlock) data=\(rxData)/\(bufferDataShards) parity=\(rxParity)/\(bufferParityShards) missing=\(missing)")
        return true
    }

    // MARK: - Private: output

    /// Append this block's data payloads in sequence order to the frame assembly.
    /// Data shards occupy slot indices 0..<bufferDataShards (parity packets always
    /// land at idx >= bufferDataShards), so the loop range excludes parity by design.
    ///
    /// `fillLost` (PyroWave partial delivery only): a missing data shard is replaced by a
    /// full payload of zeros and recorded as lost, so every later payload keeps its offset.
    private func stageBlock(fillLost: Bool = false) {
        var packets = 0
        var payloadBytes = 0
        let payloadSize = blockSize - kRtpHeaderSize - kNvPacketSize
        for i in 0..<bufferDataShards {
            guard slotUsed[i] else {
                if fillLost && partialDelivery {
                    payloadStarts.append(frameAssembly.count)
                    payloadLost.append(true)
                    payloadRecordStart.append(false)
                    payloadLostCount += 1
                    frameAssembly.append(contentsOf: repeatElement(0, count: payloadSize))
                    payloadBytes += payloadSize
                }
                continue
            }
            let baseOffset = kRtpHeaderSize + kNvPacketSize
            let frameHeaderSize: Int
            if slotFlags[i] & kFlagSOF != 0 && multiFecCurrentBlock == 0 {
                // SOF of the first FEC block carries the per-frame metadata header.
                // Size is encoded in the first byte: 0x01 → 8 B, 0x81 → extended.
                let firstByte: UInt8 = baseOffset < slotData[i].count ? slotData[i][baseOffset] : 0x01
                frameHeaderSize = firstByte == 0x81 ? kFrameHeaderSizeExtended : kFrameHeaderSizeStandard
                // Frame-type byte lives at offset +3 of the SOF frame header
                // (1=P, 2=IDR, 4=intra-refresh, 5=P-ref-inval). Used for AV1 IDR
                // detection; H.264/HEVC keep using SPS/VPS arrival and ignore this.
                let meta = FrameMeta.parseShortHeader(slotData[i], headerOffset: baseOffset)
                currentFrameType = meta.frameType
                currentLastPayloadLen = meta.lastPayloadLen
                currentCriticalPackets = meta.pyroWaveCriticalPackets
                currentFrameFlagsUsable = firstByte == 0x01
                    && slotData[i][kRtpHeaderSize + 9] & kExtraFlagRecordStart != 0
                if frameLogCount < 8 {
                    StreamLog.log("[rtp/queue] frame header firstByte=0x\(String(format: "%02x", firstByte)) size=\(frameHeaderSize) frameType=\(currentFrameType)")
                }
            } else {
                frameHeaderSize = 0
            }
            let payloadStart = baseOffset + frameHeaderSize
            let payloadEnd   = min(slotLength[i], blockSize)  // cap to stored buffer size
            guard payloadStart < payloadEnd else { continue }
            if partialDelivery {
                payloadStarts.append(frameAssembly.count)
                payloadLost.append(false)
                payloadRecordStart.append(slotData[i][kRtpHeaderSize + 9] & kExtraFlagRecordStart != 0)
            }
            frameAssembly.append(contentsOf: slotData[i][payloadStart..<payloadEnd])
            payloadBytes += payloadEnd - payloadStart
            packets += 1
        }
        frameAssemblyPackets += packets
        if frameLogCount < 8 {
            StreamLog.log("[rtp/queue] stage frame=\(currentFrameNumber) block=\(multiFecCurrentBlock)/\(multiFecLastBlock) packets=\(packets)/\(bufferDataShards) payloadBytes=\(payloadBytes)")
        }
    }

    // MARK: - Private: PyroWave partial delivery (D10)

    /// Stages the current block even though data packets are missing, replacing them with zeros.
    /// Returns false, changing nothing, when the frame cannot be delivered partially: the first
    /// packet (frame header and sequence header) is missing, the frame does not announce a
    /// critical prefix or does not flag record starts, or a critical packet is among the missing.
    private func stageIncompleteBlock() -> Bool {
        guard partialBlocker() == nil else { return false }
        stageBlock(fillLost: true)
        return true
    }

    /// Why the current (incomplete) block cannot be staged with zeros, or nil when it can.
    /// Changes nothing.
    private func partialBlocker() -> PartialDropReasonLocal? {
        guard partialDelivery, bufferDataShards > 0 else { return .ineligible }
        let base = kRtpHeaderSize + kNvPacketSize
        var critical = currentCriticalPackets
        if multiFecCurrentBlock != 0 {
            guard currentFrameFlagsUsable else { return .ineligible }
        } else {
            guard slotUsed[0], slotFlags[0] & kFlagSOF != 0 else { return .firstPacket }
            let row = slotData[0]
            // Only the 8-byte short header carries the critical packet count and lastPayloadLen.
            guard row.count > base + 8, row[base] == 0x01 else { return .ineligible }
            guard row[kRtpHeaderSize + 9] & kExtraFlagRecordStart != 0 else { return .ineligible }
            critical = FrameMeta.parseShortHeader(row, headerOffset: base).pyroWaveCriticalPackets
        }
        guard critical > 0 else { return .ineligible }
        let staged = payloadStarts.count
        if staged < critical {
            for i in 0..<bufferDataShards where !slotUsed[i] && staged + i < critical { return .critical }
        }
        return nil
    }

    private typealias PartialDropReasonLocal = StreamStatsCollector.PartialDropReason

    private func notePartialDrop(_ reason: PartialDropReasonLocal) {
        if partialDelivery { stats?.recordPartialDrop(reason) }
    }

    /// The final block is incomplete and its frame is ending: stage it with zeros and emit the
    /// frame. Leaves the queue at the start of the next frame. False (nothing changed) when the
    /// partial delivery rules are not met.
    private func deliverPartialFrame(byDeadline: Bool) -> Bool {
        guard stageIncompleteBlock() else { return false }
        pendingDeadline = nil
        stats?.recordPartialRelease(byDeadline: byDeadline)
        lastPartialFrame = currentFrameNumber
        lastPartialDeliveredAt = clock()
        submitFrame()
        currentFrameNumber &+= 1
        multiFecCurrentBlock = 0
        clearFrameAssembly()
        clearBlockSlots()
        rsCodec = nil
        return true
    }

    /// Arms (or renews) the 1 ms silence deadline: only for the final block of a frame, only
    /// when it has no parity, and only once its last data packet itself has arrived. If that
    /// packet is missing no deadline is armed, because a host pacing gap would look like loss;
    /// the frame then waits for its remaining data or the next frame boundary.
    private func armSilenceDeadlineIfEligible() {
        guard partialDelivery, bufferParityShards == 0, bufferDataShards > 0,
              multiFecCurrentBlock == multiFecLastBlock, slotUsed[bufferDataShards - 1] else { return }
        pendingDeadline = clock() + Self.silenceDeadlineSeconds
    }

    /// Called by the receive loop when it has waited until `pendingDeadline` with nothing left in
    /// the socket. Delivers the final block with its holes zero filled when the rules allow;
    /// otherwise leaves the frame to boundary based handling. Returns true when a frame was emitted.
    @discardableResult
    func expirePending() -> Bool {
        guard let deadline = pendingDeadline, clock() >= deadline else { return false }
        pendingDeadline = nil
        guard partialDelivery, havePacketsInBlock, bufferParityShards == 0,
              multiFecCurrentBlock == multiFecLastBlock else { return false }
        return deliverPartialFrame(byDeadline: true)
    }

    /// Emit the assembled frame via onFrameAssembled as a borrowed buffer view.
    private func submitFrame() {
        if frameLogCount < 8 {
            StreamLog.log("[rtp/queue] emit frame=\(currentFrameNumber) packets=\(frameAssemblyPackets) payloadBytes=\(frameAssembly.count)")
            frameLogCount += 1
        }
        let ts = currentFrameRtpTimestamp
        stats?.recordFrameAssembled(rtpTimestamp: ts)
        let frame = currentFrameNumber
        var meta = FrameMeta(frameType: currentFrameType,
                             lastPayloadLen: currentLastPayloadLen,
                             pyroWaveCriticalPackets: currentCriticalPackets)
        if partialDelivery, payloadLostCount > 0 {
            meta.lossMap = PyroWaveLossMap(payloadStarts: payloadStarts, lost: payloadLost,
                                           recordStart: payloadRecordStart)
            stats?.recordFramePartial(lostPackets: payloadLostCount)
        }
        frameAssembly.withUnsafeBufferPointer { buf in
            onFrameAssembled?(frame, buf, ts, meta)
        }
    }

    // MARK: - Private: arithmetic

    // 16-bit sequence number "before" comparison, handling wraparound.
    // Equivalent to moonlight-common-c isBefore16(): signed difference < 0.
    @inline(__always)
    private func isBefore16(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) < 0
    }

    @inline(__always)
    private func le32(_ d: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
        guard i + 3 < d.count else { return 0 }
        return UInt32(d[i]) | UInt32(d[i+1]) << 8 | UInt32(d[i+2]) << 16 | UInt32(d[i+3]) << 24
    }

    // @autoclosure: the reason string is built only if it will actually be logged.
    // These run on the per-packet hot path — without the autoclosure, every reject
    // (duplicates, stale packets) paid for string interpolation even after the
    // 8-line log cap was reached.
    private func reject(_ reason: @autoclosure () -> String) -> RtpvAddResult {
        if StreamLog.verbose && rejectLogCount < 8 {
            StreamLog.log("[rtp/queue] reject \(reason())")
            rejectLogCount += 1
        }
        return .rejected
    }

    private func logFec(_ message: @autoclosure () -> String) {
        if StreamLog.verbose && fecLogCount < 12 {
            StreamLog.log("[rtp/queue] \(message())")
            fecLogCount += 1
        }
    }

    private func flagString(_ flags: UInt8) -> String {
        var parts: [String] = []
        if flags & kFlagSOF != 0 { parts.append("SOF") }
        if flags & kFlagEOF != 0 { parts.append("EOF") }
        if flags & kFlagPIC != 0 { parts.append("PIC") }
        if parts.isEmpty { parts.append("0") }
        return "\(parts.joined(separator: "|"))(0x\(String(format: "%02x", flags)))"
    }
}

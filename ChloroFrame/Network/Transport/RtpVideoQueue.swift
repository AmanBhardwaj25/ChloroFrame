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

    // Emitted once per fully assembled frame with a borrowed view of the complete
    // Annex-B byte stream (all blocks, in sequence order).
    // Parameters: (frameIndex, annexBBytes, rtpTimestamp)
    // rtpTimestamp is the RTP timestamp of the frame (90 kHz clock, big-endian bytes 4-7 of RTP header).
    // The pointer is only valid for the duration of the call — copy if it must outlive it.
    var onFrameAssembled: ((UInt32, UnsafeBufferPointer<UInt8>, UInt32) -> Void)?

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

    private var packetLogCount = 0
    private var blockLogCount = 0
    private var frameLogCount = 0
    private var fecLogCount = 0
    private var rejectLogCount = 0

    init(packetSize: Int = 1392, useSwiftFEC: Bool = false) {
        self.packetSize = packetSize
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
                    // Frame changed — the in-progress frame is unrecoverable.
                    if !reportedLostFrame {
                        onFrameLost?(currentFrameNumber)
                        stats?.recordFrameLost()
                        reportedLostFrame = true
                    }
                    purge()
                    clearFrameAssembly()
                } else {
                    // Same frame, different FEC block — we missed a block; can't recover.
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
                // Old frame ended cleanly but we skipped some frames.
                clearFrameAssembly()
            }

            initBlock(seqNum: seqNum, frameIndex: frameIndex,
                      fecIndex: fecIndex, fecInfo: fecInfo,
                      fecBlock: fecBlock, fecLast: fecLast)

            // Capture the RTP timestamp (90 kHz, BE bytes 4-7) on the first FEC block of each frame.
            // All packets in a frame share the same RTP timestamp, so we only need one.
            if fecBlock == 0 {
                currentFrameRtpTimestamp = UInt32(datagram[4]) << 24 | UInt32(datagram[5]) << 16
                                         | UInt32(datagram[6]) << 8  | UInt32(datagram[7])
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
        guard tryReconstruct() else { return .queued }

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
    }

    /// Mark all slots free for the next block (row buffers are retained and reused).
    private func clearBlockSlots() {
        for i in slotUsed.indices { slotUsed[i] = false }
        havePacketsInBlock = false
    }

    private func clearFrameAssembly() {
        frameAssembly.removeAll(keepingCapacity: true)
        frameAssemblyPackets = 0
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
    private func stageBlock() {
        var packets = 0
        var payloadBytes = 0
        for i in 0..<bufferDataShards {
            guard slotUsed[i] else { continue }
            let baseOffset = kRtpHeaderSize + kNvPacketSize
            let frameHeaderSize: Int
            if slotFlags[i] & kFlagSOF != 0 && multiFecCurrentBlock == 0 {
                // SOF of the first FEC block carries the per-frame metadata header.
                // Size is encoded in the first byte: 0x01 → 8 B, 0x81 → extended.
                let firstByte: UInt8 = baseOffset < slotData[i].count ? slotData[i][baseOffset] : 0x01
                frameHeaderSize = firstByte == 0x81 ? kFrameHeaderSizeExtended : kFrameHeaderSizeStandard
                if frameLogCount < 8 {
                    StreamLog.log("[rtp/queue] frame header firstByte=0x\(String(format: "%02x", firstByte)) size=\(frameHeaderSize)")
                }
            } else {
                frameHeaderSize = 0
            }
            let payloadStart = baseOffset + frameHeaderSize
            let payloadEnd   = min(slotLength[i], blockSize)  // cap to stored buffer size
            guard payloadStart < payloadEnd else { continue }
            frameAssembly.append(contentsOf: slotData[i][payloadStart..<payloadEnd])
            payloadBytes += payloadEnd - payloadStart
            packets += 1
        }
        frameAssemblyPackets += packets
        if frameLogCount < 8 {
            StreamLog.log("[rtp/queue] stage frame=\(currentFrameNumber) block=\(multiFecCurrentBlock)/\(multiFecLastBlock) packets=\(packets)/\(bufferDataShards) payloadBytes=\(payloadBytes)")
        }
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
        frameAssembly.withUnsafeBufferPointer { buf in
            onFrameAssembled?(frame, buf, ts)
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

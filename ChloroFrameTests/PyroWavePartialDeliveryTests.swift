//
//  PyroWavePartialDeliveryTests.swift
//  ChloroFrameTests
//
//  D10: partial-frame recovery. Queue rules (interior drop, critical drop, first packet drop,
//  whole block drop, reorder, silence deadline), the loss-map parser entry point, a fuzz pass over
//  it, and end to end frames that decode with dropped interior packets.
//

import XCTest
import CoreMedia
import Metal
import QuartzCore
@testable import ChloroFrame

@MainActor
final class PyroWavePartialDeliveryTests: XCTestCase {

    private let packetSize = 1392
    private var P: Int { packetSize - 16 }

    // MARK: - Synthetic host: payloads to datagrams

    private struct SynthFrame {
        var index: UInt32
        var payloads: [[UInt8]]      // every payload is exactly P bytes; payload 0 starts with the 8-byte header
        var blocks: [Int]            // data shards per FEC block
        var parityPct: [Int]         // per block
        var recordStart: [Bool]
    }

    /// Frame whose payload `k` is filled with `k + 1`, with an 8-byte short header in front.
    private func synthFrame(index: UInt32, blocks: [Int], parityPct: [Int]? = nil, critical: Int,
                            lastPayloadLen: Int = 1000) -> SynthFrame {
        let total = blocks.reduce(0, +)
        var payloads = (0..<total).map { [UInt8](repeating: UInt8(truncatingIfNeeded: $0 + 1), count: P) }
        let header: [UInt8] = [0x01, 0, 0, 2, UInt8(lastPayloadLen & 0xFF), UInt8(lastPayloadLen >> 8),
                               UInt8(critical & 0xFF), UInt8(critical >> 8)]
        payloads[0].replaceSubrange(0..<8, with: header)
        return SynthFrame(index: index, payloads: payloads, blocks: blocks,
                          parityPct: parityPct ?? [Int](repeating: 0, count: blocks.count),
                          recordStart: [Bool](repeating: true, count: total))
    }

    /// Wire datagrams of `frame`. `drop` holds global data payload indices that never arrive.
    /// Parity packets are only sent when `sendParity` is set (their bytes are zeros: tests that
    /// send them never need a real recovery).
    private func datagrams(_ f: SynthFrame, seqStart: UInt16, timestamp: UInt32 = 90_000,
                           drop: Set<Int> = [], sendParity: Bool = false)
        -> (packets: [[UInt8]], nextSeq: UInt16) {
        var out: [[UInt8]] = []
        var seq = seqStart
        var global = 0
        for (block, dataShards) in f.blocks.enumerated() {
            let parity = (dataShards * f.parityPct[block] + 99) / 100
            for i in 0..<(dataShards + parity) {
                let isParity = i >= dataShards
                defer { seq = seq &+ 1 }
                var d = [UInt8](repeating: 0, count: 32)
                d[0] = 0x90
                d[2] = UInt8(seq >> 8); d[3] = UInt8(seq & 0xFF)
                for s in 0..<4 { d[4 + s] = UInt8((timestamp >> UInt32(24 - 8 * s)) & 0xFF) }
                let nb = 16
                for s in 0..<4 { d[nb + 4 + s] = UInt8((f.index >> UInt32(8 * s)) & 0xFF) }
                var flags: UInt8 = 0x01
                if i == 0 { flags = 0x04 } else if i == dataShards - 1 { flags = 0x02 }
                d[nb + 8] = flags
                let payloadIndex = global + i
                d[nb + 9] = (!isParity && f.recordStart[payloadIndex]) ? 0x80 : 0
                d[nb + 11] = UInt8(block << 4 | (f.blocks.count - 1) << 6)
                let fecInfo = UInt32(dataShards) << 22 | UInt32(i) << 12 | UInt32(f.parityPct[block]) << 4
                for s in 0..<4 { d[nb + 12 + s] = UInt8((fecInfo >> UInt32(8 * s)) & 0xFF) }
                if isParity {
                    d += [UInt8](repeating: 0, count: P)
                    if sendParity { out.append(d) }
                } else {
                    d += f.payloads[payloadIndex]
                    if !drop.contains(payloadIndex) { out.append(d) }
                }
            }
            global += dataShards
        }
        return (out, seq)
    }

    /// What the queue should assemble: payload 0 without its header, lost payloads as zeros.
    private func expectedAssembly(_ f: SynthFrame, lost: Set<Int> = []) -> [UInt8] {
        var out: [UInt8] = []
        for (k, p) in f.payloads.enumerated() {
            if lost.contains(k) { out += [UInt8](repeating: 0, count: P) }
            else if k == 0 { out += p[8...] }
            else { out += p }
        }
        return out
    }

    // MARK: - Queue harness

    private final class Sink {
        var frames: [(index: UInt32, bytes: [UInt8], meta: FrameMeta)] = []
        var lost: [UInt32] = []
    }

    private final class ClockBox { var now = 100.0 }

    private struct Harness {
        let queue: RtpVideoQueue
        let sink: Sink
        let stats: StreamStatsCollector
        let clock: ClockBox
    }

    private func harness(partial: Bool = true) -> Harness {
        let queue = RtpVideoQueue(packetSize: packetSize, partialDelivery: partial)
        let sink = Sink()
        let stats = StreamStatsCollector()
        let clock = ClockBox()
        queue.stats = stats
        queue.clock = { clock.now }
        queue.onFrameAssembled = { idx, buf, _, meta in sink.frames.append((idx, Array(buf), meta)) }
        queue.onFrameLost = { sink.lost.append($0) }
        return Harness(queue: queue, sink: sink, stats: stats, clock: clock)
    }

    private func feed(_ packets: [[UInt8]], into h: Harness) {
        for p in packets { p.withUnsafeBytes { _ = h.queue.addPacket($0) } }
    }

    /// A small complete frame that follows, so the previous frame's boundary is seen.
    private func follower(index: UInt32, seqStart: UInt16) -> [[UInt8]] {
        datagrams(synthFrame(index: index, blocks: [3], critical: 1), seqStart: seqStart).packets
    }

    // MARK: - Queue: delivery rules

    func testInteriorDropInUnprotectedFinalBlockIsDeliveredWithLossMap() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], parityPct: [20, 0], critical: 4)
        let sent = datagrams(f, seqStart: 100, drop: [25], sendParity: true)
        feed(sent.packets, into: h)
        XCTAssertTrue(h.sink.frames.isEmpty, "waits for the next frame or the silence deadline")

        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.count, 2)
        XCTAssertTrue(h.sink.lost.isEmpty)
        let first = h.sink.frames[0]
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.bytes, expectedAssembly(f, lost: [25]))
        let map = first.meta.lossMap
        XCTAssertEqual(map?.lost.enumerated().filter { $0.element }.map { $0.offset }, [25])
        XCTAssertEqual(map?.payloadStarts.count, 40)
        XCTAssertEqual(map?.payloadStarts[0], 0)
        XCTAssertEqual(map?.payloadStarts[1], P - 8)
        XCTAssertEqual(map?.payloadStarts[26], P - 8 + 25 * P)
        XCTAssertEqual(first.meta.pyroWaveCriticalPackets, 4)
        XCTAssertNil(h.sink.frames[1].meta.lossMap, "the following frame was complete")
        XCTAssertEqual(h.stats.framesPartialSoFar, 1)
        XCTAssertEqual(h.stats.framesLostSoFar, 0)
    }

    func testCompleteFrameCarriesNoLossMap() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        feed(datagrams(f, seqStart: 0).packets, into: h)
        XCTAssertEqual(h.sink.frames.count, 1)
        XCTAssertNil(h.sink.frames[0].meta.lossMap)
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f))
    }

    func testInteriorDropInAMiddleBlockIsStagedWhenTheNextBlockStarts() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 20, 20], critical: 3)
        // Payload 15 is in block 1 (indices 10..<30), which has no parity.
        feed(datagrams(f, seqStart: 0, drop: [15]).packets, into: h)
        XCTAssertEqual(h.sink.frames.count, 1)
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f, lost: [15]))
        XCTAssertEqual(h.sink.frames[0].meta.lossMap?.lostCount, 1)
        XCTAssertTrue(h.sink.lost.isEmpty)
    }

    func testCriticalPacketDropDropsTheFrame() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], parityPct: [0, 0], critical: 4)
        let sent = datagrams(f, seqStart: 0, drop: [2])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2], "only the follower is delivered")
        XCTAssertEqual(h.sink.lost, [1])
        XCTAssertEqual(h.stats.framesLostSoFar, 1)
        XCTAssertEqual(h.stats.framesPartialSoFar, 0)
    }

    func testFirstPacketDropDropsTheFrame() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        let sent = datagrams(f, seqStart: 0, drop: [0])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
    }

    func testWholeMiddleBlockDropDropsTheFrame() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 20, 20], critical: 3)
        let sent = datagrams(f, seqStart: 0, drop: Set(10..<30))
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
        XCTAssertEqual(h.stats.framesLostSoFar, 1)
    }

    func testWholeFinalBlockDropDropsTheFrameAndIsCounted() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 20], critical: 3)
        let sent = datagrams(f, seqStart: 0, drop: Set(10..<30))
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
    }

    func testReorderWithinTheFinalBlockStillAssemblesACompleteFrame() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        var packets = datagrams(f, seqStart: 0).packets
        // Shuffle the packets of block 1 (the last 30) deterministically, keeping the order
        // otherwise. Packet 0 of the block stays first so the block starts normally.
        let head = Array(packets[0..<11])
        var tail = Array(packets[11...])
        tail.reverse()
        packets = head + tail
        feed(packets, into: h)
        XCTAssertEqual(h.sink.frames.count, 1)
        XCTAssertNil(h.sink.frames[0].meta.lossMap)
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f))
    }

    func testWithoutPartialDeliveryAnInteriorDropLosesTheFrame() {
        let h = harness(partial: false)
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        let sent = datagrams(f, seqStart: 0, drop: [25])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
        XCTAssertNil(h.queue.pendingDeadline)
    }

    func testNoCriticalAnnouncementKeepsWholeFrameBehavior() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 0)
        let sent = datagrams(f, seqStart: 0, drop: [25])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
    }

    func testFirstPacketWithoutRecordStartFlagKeepsWholeFrameBehavior() {
        let h = harness()
        var f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        f.recordStart[0] = false
        let sent = datagrams(f, seqStart: 0, drop: [25])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.map { $0.index }, [2])
        XCTAssertEqual(h.sink.lost, [1])
    }

    func testRecordStartBitmapIsCarried() {
        let h = harness()
        var f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        f.recordStart[7] = false
        f.recordStart[30] = false
        let sent = datagrams(f, seqStart: 0, drop: [25])
        feed(sent.packets, into: h)
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        let map = h.sink.frames[0].meta.lossMap
        XCTAssertEqual(map?.recordStart.enumerated().filter { !$0.element }.map { $0.offset }, [7, 25, 30],
                       "payload 25 is lost, so it is not a usable record start either")
    }

    // MARK: - Queue: silence deadline

    func testSilenceDeadlineDeliversTheFrameWithoutWaitingForTheNextOne() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        feed(datagrams(f, seqStart: 0, drop: [25]).packets, into: h)

        let deadline = h.queue.pendingDeadline
        XCTAssertEqual(deadline, 100.0 + RtpVideoQueue.silenceDeadlineSeconds)
        XCTAssertEqual(RtpVideoQueue.silenceDeadlineSeconds, 0.001)
        XCTAssertFalse(h.queue.expirePending(), "not before the deadline")
        XCTAssertTrue(h.sink.frames.isEmpty)

        h.clock.now = 100.0011
        XCTAssertTrue(h.queue.expirePending())
        XCTAssertEqual(h.sink.frames.count, 1)
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f, lost: [25]))
        XCTAssertNil(h.queue.pendingDeadline)

        // Detail arriving after expiry is discarded, and the next frame still works.
        let late = datagrams(f, seqStart: 0).packets[25]
        feed([late], into: h)
        XCTAssertEqual(h.sink.frames.count, 1)
        feed(follower(index: 2, seqStart: 1000), into: h)
        XCTAssertEqual(h.sink.frames.count, 2)
        XCTAssertTrue(h.sink.lost.isEmpty)
    }

    func testNoDeadlineWhileTheFinalDataPacketIsMissing() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        let sent = datagrams(f, seqStart: 0, drop: [39])      // the final data packet
        feed(sent.packets, into: h)
        XCTAssertNil(h.queue.pendingDeadline)
        XCTAssertFalse(h.queue.expirePending())
        XCTAssertTrue(h.sink.frames.isEmpty)

        // The next frame boundary delivers it, with the tail replaced by zeros.
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.count, 2)
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f, lost: [39]))
        XCTAssertEqual(h.sink.frames[0].meta.lossMap?.lost.last, true)
    }

    func testDuplicateDoesNotRenewTheDeadlineButAReorderedPacketDoes() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        let all = datagrams(f, seqStart: 0).packets
        let withheldA = all[20], withheldB = all[21]   // no parity: packet index == payload index
        let sent = datagrams(f, seqStart: 0, drop: [20, 21]).packets
        feed(sent, into: h)
        let first = try? XCTUnwrap(h.queue.pendingDeadline)

        h.clock.now = 100.0005
        feed([sent[15]], into: h)                              // duplicate
        XCTAssertEqual(h.queue.pendingDeadline, first, "a duplicate must not prolong the deadline")

        feed([withheldA], into: h)                             // unique, reordered
        let second = h.queue.pendingDeadline
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second ?? 0, first ?? 0)
        h.clock.now = first ?? 0
        XCTAssertFalse(h.queue.expirePending(), "the old deadline cannot flush after progress")

        h.clock.now = second ?? 0
        XCTAssertTrue(h.queue.expirePending())
        XCTAssertEqual(h.sink.frames[0].meta.lossMap?.lostCount, 1, "only the packet still absent is zeroed")
        XCTAssertEqual(h.sink.frames[0].bytes, expectedAssembly(f, lost: [21]))
        _ = withheldB
    }

    func testRecoveryOfTheLastMissingPacketCompletesTheFrameWhole() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        let all = datagrams(f, seqStart: 0).packets
        feed(datagrams(f, seqStart: 0, drop: [20]).packets, into: h)
        XCTAssertNotNil(h.queue.pendingDeadline)
        feed([all[20]], into: h)
        XCTAssertEqual(h.sink.frames.count, 1)
        XCTAssertNil(h.sink.frames[0].meta.lossMap)
        XCTAssertNil(h.queue.pendingDeadline)
    }

    func testParityProtectedFinalBlockHasNoSilenceDeadline() {
        let h = harness()
        let f = synthFrame(index: 1, blocks: [10, 30], parityPct: [20, 10], critical: 4)
        let sent = datagrams(f, seqStart: 0, drop: [25])      // parity never arrives
        feed(sent.packets, into: h)
        XCTAssertNil(h.queue.pendingDeadline)
        XCTAssertFalse(h.queue.expirePending(), "a parity block keeps boundary based recovery")
        feed(follower(index: 2, seqStart: sent.nextSeq), into: h)
        XCTAssertEqual(h.sink.frames.count, 2, "the boundary still delivers it partially")
        XCTAssertEqual(h.sink.frames[0].meta.lossMap?.lostCount, 1)
    }

    func testExpiryWithACriticalPacketMissingFallsBackToTheBoundary() {
        let h = harness()
        // One block only, no parity, a critical packet (index 2) missing, final packet present.
        let f = synthFrame(index: 1, blocks: [20], critical: 4)
        feed(datagrams(f, seqStart: 0, drop: [2]).packets, into: h)
        h.clock.now = 101
        XCTAssertFalse(h.queue.expirePending())
        XCTAssertTrue(h.sink.frames.isEmpty)
        XCTAssertNil(h.queue.pendingDeadline)
    }

    func testDeadlineIsNotArmedForOtherCodecs() {
        let h = harness(partial: false)
        let f = synthFrame(index: 1, blocks: [10, 30], critical: 4)
        feed(datagrams(f, seqStart: 0, drop: [25]).packets, into: h)
        XCTAssertNil(h.queue.pendingDeadline)
    }

    // MARK: - Parser with a loss map

    private typealias Parser = PyroWaveRecordParser
    private let format = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 8)

    private func word(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }
    private func sequenceHeader(totalBlocks: Int) -> [UInt8] {
        word(UInt32(1920 - 1) | (UInt32(1080 - 1) << 14) | (1 << 31)) + word(UInt32(totalBlocks))
    }
    private func block(words: Int, index: Int) -> [UInt8] {
        var out = word(0x5A5A | (UInt32(words) << 16)) + word(7 | (UInt32(index) << 8))
        if words > 2 { for i in 2..<words { out += word(UInt32(index << 12 | i)) } }
        return out
    }
    private func padding(words n: Int) -> [UInt8] {
        word(0xFFFF_FFFF) + word(UInt32(n)) + [UInt8](repeating: 0, count: 4 * n)
    }

    /// Lays `records` end to end and cuts the stream into payloads of `payload` bytes. A payload
    /// is flagged when a record starts exactly at its first byte (payload 0 always is).
    private func layout(_ records: [[UInt8]], payload: Int, lost: Set<Int>)
        -> (bytes: [UInt8], map: PyroWaveLossMap, starts: [Int]) {
        var bytes: [UInt8] = []
        var recordOffsets = Set<Int>()
        var starts: [Int] = []
        for r in records { starts.append(bytes.count); recordOffsets.insert(bytes.count); bytes += r }
        let count = (bytes.count + payload - 1) / payload
        let payloadStarts = (0..<count).map { $0 * payload }
        // Lost payloads are zero filled, exactly like the queue does.
        for k in lost where k < count { for i in payloadStarts[k]..<min(bytes.count, payloadStarts[k] + payload) { bytes[i] = 0 } }
        let map = PyroWaveLossMap(payloadStarts: payloadStarts,
                                  lost: (0..<count).map { lost.contains($0) },
                                  recordStart: (0..<count).map { recordOffsets.contains(payloadStarts[$0]) })
        return (bytes, map, starts)
    }

    private func parse(_ bytes: [UInt8], _ map: PyroWaveLossMap?) -> Result<Parser.Frame, Parser.Failure> {
        bytes.withUnsafeBytes { Parser.parse($0, expected: format, lossMap: map) }
    }

    func testLossMapWithNothingLostEqualsTheStrictParser() throws {
        let records = [sequenceHeader(totalBlocks: 3), block(words: 10, index: 0),
                       padding(words: 3), block(words: 40, index: 1), block(words: 6, index: 2)]
        let l = layout(records, payload: 48, lost: [])
        let strict = try l.bytes.withUnsafeBytes { try Parser.parse($0, expected: format).get() }
        let mapped = try parse(l.bytes, l.map).get()
        XCTAssertEqual(strict, mapped)
        XCTAssertEqual(mapped.skippedRecords, 0)
    }

    func testRecordTouchingALostPayloadIsSkippedAndTheNextOneIsKept() throws {
        // Payload size 48: the 40 word (160 byte) block spans payloads 1..4.
        let records = [sequenceHeader(totalBlocks: 3), block(words: 10, index: 0),
                       block(words: 40, index: 1), block(words: 6, index: 2)]
        let l = layout(records, payload: 48, lost: [2])
        let f = try parse(l.bytes, l.map).get()
        XCTAssertEqual(f.blockRecordCount, 2)
        XCTAssertEqual(f.skippedRecords, 1)
        XCTAssertEqual(f.resyncs, 0, "the skipped record's header arrived, so its end was known")
        XCTAssertEqual(f.records.count, 3)
        XCTAssertEqual(f.records[1], l.starts[1]..<l.starts[1] + 40)
        XCTAssertEqual(f.records[2], l.starts[3]..<l.starts[3] + 24)
    }

    func testLostHeaderResumesAtTheNextRecordStartPayload() throws {
        // Header (8) + padding (16) put the first block at byte 24, so with 24 byte records and
        // 48 byte payloads a record starts at every payload start: payloads 0..4 are all flagged.
        let records = [sequenceHeader(totalBlocks: 8), padding(words: 2)]
            + (0..<8).map { block(words: 6, index: $0) }                // 24..<216
        let l = layout(records, payload: 48, lost: [1])                 // bytes 48..<96
        XCTAssertEqual(l.map.recordStart, [true, true, true, true, true])
        let f = try parse(l.bytes, l.map).get()
        // The blocks at 48 and 72 were in the lost payload; their headers are gone, so parsing
        // jumps to the next received payload that starts with a record (96).
        XCTAssertEqual(f.resyncs, 1)
        XCTAssertEqual(f.blockRecordCount, 6)
        for r in f.records {
            XCTAssertFalse(r.overlaps(48..<96), "no kept record may touch the lost payload")
        }
        XCTAssertEqual(f.records.first, 0..<8)
        XCTAssertEqual(f.records[1], 24..<48)
        XCTAssertEqual(f.records[2], 96..<120)
        XCTAssertEqual(f.records.last?.upperBound, 216)
    }

    func testNoFlaggedPayloadAfterALostHeaderGivesUpTheRest() throws {
        // A header, a small record (8..<24), then a big record whose header is at byte 24.
        let records = [sequenceHeader(totalBlocks: 2), block(words: 4, index: 0), block(words: 60, index: 1)]
        let l = layout(records, payload: 16, lost: [])
        // Payloads of 16 bytes; lose payload 1 (bytes 16..<32), which holds the big record's header,
        // and flag no payload after it as a record start.
        let n = l.map.payloadStarts.count
        let map = PyroWaveLossMap(payloadStarts: l.map.payloadStarts,
                                  lost: (0..<n).map { $0 == 1 },
                                  recordStart: (0..<n).map { $0 == 0 })
        var bytes = l.bytes
        for i in 16..<32 { bytes[i] = 0 }
        let f = try parse(bytes, map).get()
        // Record at 8..<24 touches the lost payload: skipped with a known end; the next header
        // (24) is lost: nothing flagged follows, so the rest of the frame is given up.
        XCTAssertEqual(f.records, [0..<8])
        XCTAssertEqual(f.blockRecordCount, 0)
    }

    func testLostSequenceHeaderFailsTheFrame() {
        let records = [sequenceHeader(totalBlocks: 1), block(words: 10, index: 0)]
        let l = layout(records, payload: 48, lost: [0])
        if case .success = parse(l.bytes, l.map) { XCTFail("must fail without the sequence header") }
    }

    func testEverythingButTheHeaderLostParsesToZeroBlocks() throws {
        let records = [sequenceHeader(totalBlocks: 2), block(words: 20, index: 0), block(words: 20, index: 1)]
        // Payloads of 8 bytes would be unusual; use 16 and lose every payload but the first.
        let l = layout(records, payload: 16, lost: Set(1..<20))
        let f = try parse(l.bytes, l.map).get()
        XCTAssertEqual(f.blockRecordCount, 0)
        XCTAssertEqual(f.totalBlocks, 2)
    }

    func testStrictBehaviorWithoutAMapIsUnchangedForTruncation() {
        let bytes = sequenceHeader(totalBlocks: 1) + [UInt8](block(words: 10, index: 0).prefix(20))
        switch parse(bytes, nil) {
        case .failure(let f): XCTAssertEqual(f, .truncatedRecord(offset: 8))
        case .success: XCTFail("a truncated record must fail strict parsing")
        }
    }

    // MARK: - Parser fuzz

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testLossMapEntryPointSurvivesTenThousandMutatedFramesAndHostileMaps() {
        var rng = SplitMix64(state: 0xD10D10)
        var records = [sequenceHeader(totalBlocks: 60)]
        for i in 0..<60 {
            records.append(block(words: Int.random(in: 2...120, using: &rng), index: i))
            if i % 7 == 0 { records.append(padding(words: Int.random(in: 0...20, using: &rng))) }
        }
        let valid = records.flatMap { $0 }
        var worst = 0.0
        var accepted = 0
        let start = CACurrentMediaTime()

        for i in 0..<10_000 {
            var b = valid
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: for _ in 0..<Int.random(in: 1...6, using: &rng) { b[Int.random(in: 0..<b.count, using: &rng)] ^= 0xFF }
            case 1: b = Array(b.prefix(Int.random(in: 0...(b.count / 4), using: &rng) * 4))
            case 2:
                let at = Int.random(in: 0..<(b.count / 4), using: &rng) * 4
                for s in 0..<4 { b[at + s] = UInt8.random(in: 0...255, using: &rng) }
            case 3:
                let a = Int.random(in: 0..<b.count, using: &rng)
                for j in a..<min(b.count, a + Int.random(in: 1...300, using: &rng)) { b[j] = 0 }
            default: break
            }
            // A loss map: usually well formed (sorted, in range), sometimes hostile.
            let payload = [16, 24, 48, 100, 1376].randomElement(using: &rng)!
            let n = max(1, (b.count + payload - 1) / payload)
            var starts = (0..<n).map { $0 * payload }
            var lost = (0..<n).map { _ in Int.random(in: 0..<5, using: &rng) == 0 }
            var flags = (0..<n).map { _ in Bool.random(using: &rng) }
            if i % 10 == 9 {
                starts = starts.map { $0 &+ Int.random(in: -40...40, using: &rng) }
                if Bool.random(using: &rng) { starts.shuffle(using: &rng) }
                if Bool.random(using: &rng) && !lost.isEmpty { lost.removeLast(); flags.removeLast(); starts.removeLast() }
            }
            let count = min(starts.count, lost.count, flags.count)
            let map = PyroWaveLossMap(payloadStarts: Array(starts.prefix(count)), lost: Array(lost.prefix(count)),
                                      recordStart: Array(flags.prefix(count)))
            let t = CACurrentMediaTime()
            let result = b.withUnsafeBytes { Parser.parse($0, expected: format, lossMap: map) }
            let dt = CACurrentMediaTime() - t
            worst = max(worst, dt)
            XCTAssertLessThan(dt, 0.1, "parse \(i) took \(dt) s")
            if case .success(let f) = result {
                accepted += 1
                for r in f.records {
                    XCTAssertGreaterThanOrEqual(r.lowerBound, 0)
                    XCTAssertLessThanOrEqual(r.upperBound, b.count)
                    XCTAssertEqual(r.lowerBound % 4, 0)
                    XCTAssertEqual(r.count % 4, 0)
                }
            }
        }
        let total = CACurrentMediaTime() - start
        XCTAssertLessThan(total, 20)
        XCTAssertGreaterThan(accepted, 500)
        DebugFileLog.write("D10 loss-map parser fuzz: 10000 frames in \(String(format: "%.2f", total)) s, "
                         + "worst \(String(format: "%.3f", worst * 1000)) ms, accepted \(accepted)")
    }

    // MARK: - End to end: real encoder, real queue, real decoder

    /// Re-lays an encoder frame like vibeshine does: critical blocks first, records never
    /// straddle a payload boundary unless oversized, padding fills the gaps. Returns the wire
    /// payloads (payload 0 starts with the 8-byte short header) and the critical packet count.
    private func hostLayout(frame: [UInt8], width: Int, height: Int)
        throws -> (payloads: [[UInt8]], critical: Int, lastPayloadLen: Int, recordStart: [Bool]) {
        let fmt = PyroWaveStreamFormat(width: width, height: height, chroma444: false, bitDepth: 8)
        let parsed = try frame.withUnsafeBytes { try Parser.parse($0, expected: fmt).get() }
        let header = Array(frame[parsed.records[0]])
        let blocks = parsed.records.dropFirst().map { Array(frame[$0]) }
        func blockIndex(_ r: [UInt8]) -> Int {
            Int(r[5]) | Int(r[6]) << 8 | Int(r[7]) << 16
        }
        func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }
        let w32 = ceilDiv(max(width, 128), 32), h32 = ceilDiv(max(height, 128), 32)
        let criticalBlocks = 12 * ceilDiv(w32, 32) * ceilDiv(h32, 32)
        let groups = [blocks.filter { blockIndex($0) < criticalBlocks },
                      blocks.filter { blockIndex($0) >= criticalBlocks }]

        var wire: [UInt8] = [UInt8](repeating: 0, count: 8)    // the short header goes here later
        var starts = Set<Int>([0])
        func place(_ r: [UInt8]) {
            let pos = wire.count
            let remaining = P - pos % P
            if r.count > P - 8 {
                // Oversized: starts at a payload boundary.
                if pos % P != 0 { wire += padding(words: (remaining - 8) / 4) }
            } else if r.count > remaining || remaining - r.count == 4 {
                if remaining >= 8 { wire += padding(words: (remaining - 8) / 4) }
            }
            starts.insert(wire.count)
            wire += r
        }
        starts.insert(8)
        wire += header
        var criticalEnd = wire.count
        for (g, group) in groups.enumerated() {
            for r in group { place(r) }
            if g == 0 { criticalEnd = wire.count }
        }
        let tailRemaining = P - wire.count % P
        XCTAssertNotEqual(tailRemaining, 4 % P, "test layout cannot leave a 4 byte remainder")
        let lastLen = wire.count % P == 0 ? P : wire.count % P
        wire += [UInt8](repeating: 0, count: (P - wire.count % P) % P)
        let n = wire.count / P
        let payloads = (0..<n).map { Array(wire[$0 * P..<($0 + 1) * P]) }
        // A payload is flagged when a record or padding record starts at its first byte.
        var padStarts = starts
        var i = 8
        while i < wire.count - 8 {   // walk padding records so their starts count too
            let w0 = UInt32(wire[i]) | UInt32(wire[i+1]) << 8 | UInt32(wire[i+2]) << 16 | UInt32(wire[i+3]) << 24
            if w0 == 0xFFFF_FFFF {
                padStarts.insert(i)
                let n = Int(UInt32(wire[i+4]) | UInt32(wire[i+5]) << 8 | UInt32(wire[i+6]) << 16 | UInt32(wire[i+7]) << 24)
                i += 8 + 4 * n
            } else if w0 & 0x8000_0000 != 0 {
                i += 8
            } else {
                let words = Int((w0 >> 16) & 0xFFF)
                if words < 2 { break }          // the zero tail of the last payload
                i += words * 4
            }
        }
        let flags = (0..<n).map { padStarts.contains($0 * P) }
        let critical = (criticalEnd + P - 1) / P
        return (payloads, critical, lastLen, flags)
    }

    private func encodeFrame(width: Int, height: Int, budget: Int) throws -> (frame: [UInt8], y: [UInt8]) {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shared = try PyroWaveDevice.shared(for: device)
        let encoder = try PyroWaveEncoder(device: shared, width: width, height: height, chroma444: false)
        let img = PyroWaveDecodeBenchmark.syntheticImage(width: width, height: height, chroma444: false)
        var frame = Data()
        for p in try encoder.encode(y: img.y, cb: img.cb, cr: img.cr, maximumBitstreamSize: budget) {
            frame.append(p)
        }
        return ([UInt8](frame), img.y)
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var se = 0.0
        for i in 0..<min(a.count, b.count) { let d = Double(a[i]) - Double(b[i]); se += d * d }
        let mse = se / Double(max(1, min(a.count, b.count)))
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Splits the host layout into FEC blocks: a critical block with parity, then blocks of at
    /// most 100 packets with none, like the host's plan.
    private func fecBlocks(total: Int, critical: Int) -> (blocks: [Int], pct: [Int]) {
        var blocks = [min(total, critical + 4)]
        var rest = total - blocks[0]
        while rest > 0 { let n = min(rest, 100); blocks.append(n); rest -= n }
        return (blocks, [20] + [Int](repeating: 0, count: blocks.count - 1))
    }

    private func decodeThroughQueue(_ synth: SynthFrame, lastPayloadLen: Int, drop: Set<Int>,
                                    width: Int, height: Int, decoder: PyroWaveDecoder,
                                    expiry: Bool) async throws -> [UInt8] {
        let h = harness()
        let sent = datagrams(synth, seqStart: 0, drop: drop, sendParity: false)
        feed(sent.packets, into: h)
        if expiry {
            h.clock.now = 200
            _ = h.queue.expirePending()
        } else {
            feed(follower(index: synth.index + 1, seqStart: sent.nextSeq), into: h)
        }
        let delivered = try XCTUnwrap(h.sink.frames.first, "frame not delivered, lost=\(h.sink.lost)")
        DebugFileLog.write("D10 e2e delivered \(delivered.bytes.count) bytes, head \(delivered.bytes.prefix(16)), meta \(delivered.meta.frameType) \(delivered.meta.lastPayloadLen) \(delivered.meta.pyroWaveCriticalPackets)")
        let valid = try PyroWaveFrameTrim.validLength(assembledCount: delivered.bytes.count,
                                                      lastPayloadLen: delivered.meta.lastPayloadLen,
                                                      packetSize: packetSize).get()
        decoder.submit(frame: Data(delivered.bytes[0..<valid]), pts: .zero, lossMap: delivered.meta.lossMap)
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let c = decoder.counterSnapshot
            if c.decoded + c.parseRejects + c.pushRejects + c.incomplete + c.gpuFailures >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return delivered.bytes
    }

    func testFrameWithDroppedInteriorPacketsDecodesWithAPsnrFloor() async throws {
        let (w, h) = (640, 360)
        let (frame, sourceY) = try encodeFrame(width: w, height: h, budget: 150_000)
        let layout = try hostLayout(frame: frame, width: w, height: h)
        XCTAssertGreaterThan(layout.payloads.count, layout.critical + 20,
                             "the test frame needs interior detail packets to drop")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: w, height: h, chroma444: false, bitDepth: 8)

        func decodeLuma(drop: Set<Int>, expiry: Bool) async throws -> (luma: [UInt8], counters: PyroWaveDecoder.Counters) {
            let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
            var luma: [UInt8]?
            decoder.onFrameDecoded = { f, _ in
                var l = [UInt8](repeating: 0, count: w * h)
                f.y.getBytes(&l, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                luma = l
            }
            let blocks = fecBlocks(total: layout.payloads.count, critical: layout.critical)
            var synth = SynthFrame(index: 1, payloads: layout.payloads, blocks: blocks.blocks,
                                   parityPct: blocks.pct, recordStart: layout.recordStart)
            // The header bytes are already in payload 0; set the critical count and length.
            synth.payloads[0].replaceSubrange(0..<8, with: [0x01, 0, 0, 2, UInt8(layout.lastPayloadLen & 0xFF),
                                                           UInt8(layout.lastPayloadLen >> 8),
                                                           UInt8(layout.critical & 0xFF), UInt8(layout.critical >> 8)])
            _ = try await decodeThroughQueue(synth, lastPayloadLen: layout.lastPayloadLen, drop: drop,
                                             width: w, height: h, decoder: decoder, expiry: expiry)
            // Wait for the GPU handler to deliver the frame.
            let end = Date().addingTimeInterval(5)
            while luma == nil, Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
            return (try XCTUnwrap(luma, "no frame; counters \(decoder.counterSnapshot)"), decoder.counterSnapshot)
        }

        let whole = try await decodeLuma(drop: [], expiry: false)
        let wholePSNR = psnr(whole.luma, sourceY)
        XCTAssertEqual(whole.counters.partialDecoded, 0)

        // Drop every 9th payload after the critical prefix (all interior, none the first or last).
        var drop = Set<Int>()
        var k = layout.critical + 2
        while k < layout.payloads.count - 2 { drop.insert(k); k += 9 }
        XCTAssertGreaterThanOrEqual(drop.count, 3)

        for expiry in [false, true] {
            let partial = try await decodeLuma(drop: drop, expiry: expiry)
            let score = psnr(partial.luma, sourceY)
            DebugFileLog.write("D10 e2e partial luma PSNR \(String(format: "%.1f", score)) dB "
                + "(whole \(String(format: "%.1f", wholePSNR)) dB), dropped \(drop.count) of \(layout.payloads.count) payloads, "
                + "skipped blocks \(partial.counters.blocksSkipped), expiry=\(expiry)")
            XCTAssertEqual(partial.counters.partialDecoded, 1)
            XCTAssertGreaterThan(partial.counters.blocksSkipped, 0)
            XCTAssertEqual(partial.counters.parseRejects, 0)
            XCTAssertEqual(partial.counters.incomplete, 0)
            XCTAssertGreaterThan(score, 25, "a frame that lost detail must still look like the source")
            XCTAssertLessThan(score, wholePSNR, "it did lose something")
        }
    }

    // MARK: - Receiver over loopback UDP: the poll() silence path

    func testReceiverDeliversAPartialFrameWithoutWaitingForTheNextFrame() async throws {
        let (w, h) = (640, 360)
        let (frame, _) = try encodeFrame(width: w, height: h, budget: 150_000)
        let layout = try hostLayout(frame: frame, width: w, height: h)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: w, height: h, chroma444: false, bitDepth: 8)
        let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
        var decodedAt: Double?
        decoder.onFrameDecoded = { _, _ in decodedAt = CACurrentMediaTime() }

        func udp() -> (fd: Int32, port: UInt16) {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            return (fd, UInt16(bigEndian: bound.sin_port))
        }
        let sender = udp()
        let probe = udp()
        let localPort = probe.port
        close(probe.fd)

        let receiver = RTPVideoReceiver(decoder: VideoDecoder(), packetSize: packetSize, videoCodec: .pyrowave,
                                        streamFps: 60, pyroWaveDecoder: decoder)
        try await receiver.start(host: "127.0.0.1", serverPort: sender.port, localPort: localPort,
                                 pingPayload: "0123456789ABCDEF")
        defer { receiver.stop(); close(sender.fd) }

        let blocks = fecBlocks(total: layout.payloads.count, critical: layout.critical)
        var synth = SynthFrame(index: 1, payloads: layout.payloads, blocks: blocks.blocks,
                               parityPct: blocks.pct, recordStart: layout.recordStart)
        synth.payloads[0].replaceSubrange(0..<8, with: [0x01, 0, 0, 2, UInt8(layout.lastPayloadLen & 0xFF),
                                                       UInt8(layout.lastPayloadLen >> 8),
                                                       UInt8(layout.critical & 0xFF), UInt8(layout.critical >> 8)])
        let packets = datagrams(synth, seqStart: 0, drop: [layout.critical + 5, layout.critical + 14]).packets

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = localPort.bigEndian
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        var lastSend = 0.0
        for d in packets {
            _ = d.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sender.fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            lastSend = CACurrentMediaTime()
            usleep(50)
        }
        // No following frame is ever sent: only the 1 ms silence deadline can release this one.
        let end = Date().addingTimeInterval(3)
        while decodedAt == nil, Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
        let delivered = try XCTUnwrap(decodedAt, "silence deadline never delivered the frame; \(decoder.counterSnapshot)")
        let afterLastPacketMs = (delivered - lastSend) * 1000
        DebugFileLog.write("D10 loopback: partial frame decoded \(String(format: "%.1f", afterLastPacketMs)) ms after its last packet")
        XCTAssertLessThan(afterLastPacketMs, 100, "must not wait for a next frame (16.7 ms at 60 fps, unbounded here)")
        let c = decoder.counterSnapshot
        XCTAssertEqual(c.partialDecoded, 1)
        XCTAssertEqual(c.parseRejects, 0)
    }
}

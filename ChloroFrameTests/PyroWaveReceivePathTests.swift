//
//  PyroWaveReceivePathTests.swift
//  ChloroFrameTests
//
//  D6: a synthetic PyroWave frame, packetized the way vibeshine sends it, goes through the real
//  RtpVideoQueue and the real RTPVideoReceiver (over a loopback UDP socket) into the decoder.
//  No host involved. Also the decode benchmark behind readiness check C15.
//

import XCTest
import CoreMedia
import Metal
@testable import ChloroFrame

@MainActor
final class PyroWaveReceivePathTests: XCTestCase {

    private let packetSize = 1392
    private var payloadBytes: Int { packetSize - 16 }

    // MARK: - Synthetic host side

    /// Encodes a synthetic image and returns (record frame, source planes).
    private func makeFrame(width: Int, height: Int, budget: Int = 120_000)
        throws -> (frame: Data, y: [UInt8]) {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shared = try PyroWaveDevice.shared(for: device)
        let encoder = try PyroWaveEncoder(device: shared, width: width, height: height, chroma444: false)
        let img = PyroWaveDecodeBenchmark.syntheticImage(width: width, height: height, chroma444: false)
        let packets = try encoder.encode(y: img.y, cb: img.cb, cr: img.cr, maximumBitstreamSize: budget)
        var frame = Data()
        for p in packets { frame.append(p) }
        return (frame, img.y)
    }

    /// Splits `frame` into RTP datagrams like vibeshine: 8-byte short frame header in front of
    /// the first payload, payloads of `packetSize - 16`, the last one zero padded to full size,
    /// one FEC block with no parity. Sequence numbers are `seqStart...`.
    private func datagrams(frame: Data, frameIndex: UInt32, rtpTimestamp: UInt32, seqStart: UInt16,
                           criticalPackets: Int = 0) -> [[UInt8]] {
        let p = payloadBytes
        var last = (frame.count + 8) % p
        if last == 0 { last = p }
        var stream = [UInt8]([0x01, 0, 0, 2, UInt8(last & 0xFF), UInt8(last >> 8),
                              UInt8(criticalPackets & 0xFF), UInt8(criticalPackets >> 8)])
        stream += [UInt8](frame)
        let count = (stream.count + p - 1) / p
        stream += [UInt8](repeating: 0, count: count * p - stream.count)

        return (0..<count).map { i in
            var d = [UInt8](repeating: 0, count: 16 + 16)
            let seq = seqStart &+ UInt16(i)
            d[0] = 0x90
            d[2] = UInt8(seq >> 8); d[3] = UInt8(seq & 0xFF)
            for s in 0..<4 { d[4 + s] = UInt8((rtpTimestamp >> UInt32(24 - 8 * s)) & 0xFF) }
            let nb = 16
            for s in 0..<4 { d[nb + 4 + s] = UInt8((frameIndex >> UInt32(8 * s)) & 0xFF) }
            d[nb + 8] = i == 0 ? 0x04 : (i == count - 1 ? 0x02 : 0x01)   // SOF / EOF / PIC
            d[nb + 11] = 0                                                 // one FEC block
            let fecInfo = UInt32(count) << 22 | UInt32(i) << 12            // 0% parity
            for s in 0..<4 { d[nb + 12 + s] = UInt8((fecInfo >> UInt32(8 * s)) & 0xFF) }
            d += stream[(i * p)..<((i + 1) * p)]
            return d
        }
    }

    // MARK: - RtpVideoQueue: meta and trimming

    func testQueueDeliversMetaAndTrimmedFrameEqualsTheOriginal() throws {
        let (frame, _) = try makeFrame(width: 640, height: 360)
        let queue = RtpVideoQueue(packetSize: packetSize)
        var got: (bytes: [UInt8], meta: FrameMeta)?
        queue.onFrameAssembled = { _, buf, _, meta in got = (Array(buf), meta) }

        for d in datagrams(frame: frame, frameIndex: 1, rtpTimestamp: 9000, seqStart: 100, criticalPackets: 7) {
            d.withUnsafeBytes { _ = queue.addPacket($0) }
        }
        let result = try XCTUnwrap(got)
        XCTAssertEqual(result.meta.frameType, 2)
        XCTAssertEqual(result.meta.pyroWaveCriticalPackets, 7)
        XCTAssertGreaterThan(result.meta.lastPayloadLen, 0)

        let valid = try PyroWaveFrameTrim.validLength(assembledCount: result.bytes.count,
                                                      lastPayloadLen: result.meta.lastPayloadLen,
                                                      packetSize: packetSize).get()
        XCTAssertEqual(Array(result.bytes.prefix(valid)), [UInt8](frame),
                       "trimming must give back the host's frame byte for byte")
        XCTAssertGreaterThan(result.bytes.count, valid, "the wire frame carries zero padding")
    }

    func testMetaIsResetBetweenFrames() throws {
        let (frame, _) = try makeFrame(width: 640, height: 360)
        let queue = RtpVideoQueue(packetSize: packetSize)
        var metas: [FrameMeta] = []
        queue.onFrameAssembled = { _, _, _, meta in metas.append(meta) }
        for d in datagrams(frame: frame, frameIndex: 1, rtpTimestamp: 9000, seqStart: 0, criticalPackets: 9) {
            d.withUnsafeBytes { _ = queue.addPacket($0) }
        }
        let n = UInt16(datagrams(frame: frame, frameIndex: 1, rtpTimestamp: 0, seqStart: 0).count)
        for d in datagrams(frame: frame, frameIndex: 2, rtpTimestamp: 10500, seqStart: n, criticalPackets: 0) {
            d.withUnsafeBytes { _ = queue.addPacket($0) }
        }
        XCTAssertEqual(metas.count, 2)
        XCTAssertEqual(metas[0].pyroWaveCriticalPackets, 9)
        XCTAssertEqual(metas[1].pyroWaveCriticalPackets, 0)
    }

    // MARK: - Receiver over loopback UDP

    private func bindUDP(port: UInt16 = 0) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    private func freeLocalPort() throws -> UInt16 {
        let s = try bindUDP()
        close(s.fd)
        return s.port
    }

    private func send(_ datagrams: [[UInt8]], fd: Int32, to port: UInt16) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        for d in datagrams {
            _ = d.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // Keep the loopback buffer from overflowing during the burst.
            usleep(50)
        }
    }

    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var frames: [PlanarVideoFrame] = []
        var lostCallbacks = 0
    }

    private struct Rig {
        let receiver: RTPVideoReceiver
        let decoder: PyroWaveDecoder
        let senderFD: Int32
        let localPort: UInt16
        let collected: Collected
    }

    private func makeRig(codec: VideoCodec, width: Int, height: Int) async throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: width, height: height, chroma444: false, bitDepth: 8)
        let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
        let collected = Collected()
        decoder.onFrameDecoded = { f, _ in collected.lock.withLock { collected.frames.append(f) } }

        let sender = try bindUDP()                       // plays the host: video server port
        let localPort = try freeLocalPort()              // the receiver's port
        let receiver = RTPVideoReceiver(decoder: VideoDecoder(), packetSize: packetSize, videoCodec: codec,
                                        streamFps: 60,
                                        pyroWaveDecoder: codec == .pyrowave ? decoder : nil)
        receiver.onFrameLost = { _ in collected.lock.withLock { collected.lostCallbacks += 1 } }
        try await receiver.start(host: "127.0.0.1", serverPort: sender.port, localPort: localPort,
                                 pingPayload: "0123456789ABCDEF")
        return Rig(receiver: receiver, decoder: decoder, senderFD: sender.fd, localPort: localPort,
                   collected: collected)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var se = 0.0
        for i in 0..<min(a.count, b.count) { let d = Double(a[i]) - Double(b[i]); se += d * d }
        let mse = se / Double(max(1, min(a.count, b.count)))
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    func testLoopbackFrameReachesTheDecoderAndMatchesTheSource() async throws {
        let (w, h) = (640, 360)
        let (frame, sourceY) = try makeFrame(width: w, height: h)
        let rig = try await makeRig(codec: .pyrowave, width: w, height: h)
        defer { rig.receiver.stop(); close(rig.senderFD) }

        send(datagrams(frame: frame, frameIndex: 1, rtpTimestamp: 90_000, seqStart: 0, criticalPackets: 4),
             fd: rig.senderFD, to: rig.localPort)
        await waitFor { rig.collected.lock.withLock { !rig.collected.frames.isEmpty } }

        let decoded = try XCTUnwrap(rig.collected.lock.withLock { rig.collected.frames.first },
                                    "no frame decoded; counters \(rig.decoder.counterSnapshot)")
        var luma = [UInt8](repeating: 0, count: w * h)
        decoded.y.getBytes(&luma, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let score = psnr(luma, sourceY)
        DebugFileLog.write("D6 loopback luma PSNR \(String(format: "%.1f", score)) dB, counters \(rig.decoder.counterSnapshot)")
        XCTAssertGreaterThan(score, 35)
        XCTAssertEqual(decoded.color, PlanarColorParams(bitDepth: 8, fullRange: false, matrix: .bt709, transfer: .sdr))
        let c = rig.decoder.counterSnapshot
        XCTAssertEqual(c.parseRejects, 0)
        XCTAssertEqual(c.incomplete, 0)
    }

    /// A frame with a missing packet: PyroWave does not ask for an IDR and the next frame
    /// decodes. The same loss on an HEVC receiver does fire the IDR-request callback.
    func testLostFrameDoesNotRequestAnIdrForPyroWaveButDoesForHEVC() async throws {
        let (w, h) = (640, 360)
        let (frame, _) = try makeFrame(width: w, height: h)
        let all1 = datagrams(frame: frame, frameIndex: 1, rtpTimestamp: 90_000, seqStart: 0)
        let all2 = datagrams(frame: frame, frameIndex: 2, rtpTimestamp: 91_500, seqStart: UInt16(all1.count))
        let all3 = datagrams(frame: frame, frameIndex: 3, rtpTimestamp: 93_000,
                             seqStart: UInt16(all1.count + all2.count))
        // Frame 1 loses an interior packet, frame 2 arrives whole (which makes frame 1's loss
        // visible to the queue), frame 3 follows.
        var damaged = all1
        damaged.remove(at: all1.count / 2)

        for codec in [VideoCodec.pyrowave, .hevc] {
            let rig = try await makeRig(codec: codec, width: w, height: h)
            send(damaged + all2 + all3, fd: rig.senderFD, to: rig.localPort)
            if codec == .pyrowave {
                await waitFor { rig.collected.lock.withLock { rig.collected.frames.count >= 2 } }
            } else {
                await waitFor { rig.collected.lock.withLock { rig.collected.lostCallbacks > 0 } }
            }
            let lost = rig.collected.lock.withLock { rig.collected.lostCallbacks }
            let decodedCount = rig.collected.lock.withLock { rig.collected.frames.count }
            rig.receiver.stop(); close(rig.senderFD)

            if codec == .pyrowave {
                XCTAssertEqual(lost, 0, "PyroWave must not request an IDR")
                XCTAssertEqual(decodedCount, 2, "frames 2 and 3 decode, frame 1 is dropped")
            } else {
                XCTAssertGreaterThan(lost, 0, "HEVC loss handling must be unchanged")
            }
        }
    }

    // MARK: - C15 benchmark

    func testDecodeBenchmarkIsFastAndAccurateAt1080p() async throws {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Shader compile is a one-time app cost (warmed up at negotiation), not part of the
        // benchmark's own budget.
        _ = try PyroWaveDevice.shared(for: device)

        let format = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 8)
        let m = try await PyroWaveDecodeBenchmark.measure(device: device, format: format)
        DebugFileLog.write("D6 benchmark 1080p avg \(String(format: "%.2f", m.averageGPUMs)) ms, "
              + "max \(String(format: "%.2f", m.maxGPUMs)) ms, wall \(String(format: "%.0f", m.wallMs)) ms")
        XCTAssertGreaterThan(m.averageGPUMs, 0)
        XCTAssertLessThan(m.averageGPUMs, 2.0, "C15 pass band")
        XCTAssertLessThan(m.wallMs, 1000, "benchmark must stay well under one second")
    }

    func testBenchmarkRefusesWhatItCannotMeasure() async throws {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let tenBit = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 10)
        do {
            _ = try await PyroWaveDecodeBenchmark.run(device: device, format: tenBit)
            XCTFail("10-bit must be refused until D9")
        } catch {
            XCTAssertEqual(error as? PyroWaveDecodeBenchmark.Failure, .unsupportedFormat("bit depth 10"))
        }
    }

    func testBenchmarkCacheIsPerFormat() {
        PyroWaveBenchmarkCache.removeAll()
        let a = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 8)
        let b = PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: true, bitDepth: 8)
        XCTAssertNil(PyroWaveBenchmarkCache.averageGPUMs(for: a))
        PyroWaveBenchmarkCache.store(0.42, for: a)
        XCTAssertEqual(PyroWaveBenchmarkCache.averageGPUMs(for: a), 0.42)
        XCTAssertNil(PyroWaveBenchmarkCache.averageGPUMs(for: b))
        PyroWaveBenchmarkCache.removeAll()
    }
}

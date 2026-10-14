//
//  PyroWaveHardeningTests.swift
//  ChloroFrameTests
//
//  D7: parser fuzzing, decoder and receiver lifecycle, resolution sanity, and the per-stage
//  CPU profile (also runnable against a Release build, see testProfile3024x1890).
//

import XCTest
import CoreMedia
import Metal
import QuartzCore
import MachO
@testable import ChloroFrame

/// Deterministic generator so a failing seed reproduces.
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

@MainActor
final class PyroWaveHardeningTests: XCTestCase {

    private let packetSize = 1392

    // MARK: - Helpers

    private func encodeFrame(width: Int, height: Int, budget: Int) throws -> Data {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let shared = try PyroWaveDevice.shared(for: device)
        let encoder = try PyroWaveEncoder(device: shared, width: width, height: height, chroma444: false)
        let img = PyroWaveDecodeBenchmark.syntheticImage(width: width, height: height, chroma444: false)
        var frame = Data()
        for p in try encoder.encode(y: img.y, cb: img.cb, cr: img.cr, maximumBitstreamSize: budget) {
            frame.append(p)
        }
        return frame
    }

    private func outcomes(_ c: PyroWaveDecoder.Counters) -> Int {
        c.decoded + c.parseRejects + c.pushRejects + c.incomplete + c.poolExhausted
            + c.gpuFailures + c.mailboxReplaced
    }

    /// Waits until every submitted frame has a terminal outcome.
    private func settle(_ decoder: PyroWaveDecoder, timeout: TimeInterval = 10) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let c = decoder.counterSnapshot
            if outcomes(c) >= c.submitted { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func openFileDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    // MARK: - Mutations

    private func mutate(_ valid: [UInt8], rng: inout SplitMix64) -> [UInt8] {
        var b = valid
        switch Int.random(in: 0..<10, using: &rng) {
        case 0:   // bit flips
            for _ in 0..<Int.random(in: 1...8, using: &rng) where !b.isEmpty {
                b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            }
        case 1:   // arbitrary truncation
            b = Array(b.prefix(Int.random(in: 0...b.count, using: &rng)))
        case 2:   // word aligned truncation
            b = Array(b.prefix(Int.random(in: 0...(b.count / 4), using: &rng) * 4))
        case 3:   // padding record with a hostile count
            let counts: [UInt32] = [0, 1, 7, 0xFFFF_FFFF, 0x3FFF_FFFF, 0x4000_0000, 0x7FFF_FFFF, 0x8000_0000]
            let n = counts.randomElement(using: &rng)!
            let at = Int.random(in: 0...(b.count / 4), using: &rng) * 4
            var rec: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
            for s in 0..<4 { rec.append(UInt8((n >> UInt32(8 * s)) & 0xFF)) }
            rec += [UInt8](repeating: 0, count: Int.random(in: 0...64, using: &rng) * 4)
            b.insert(contentsOf: rec, at: at)
        case 4:   // overwrite one word
            if b.count >= 4 {
                let at = Int.random(in: 0..<(b.count / 4), using: &rng) * 4
                for s in 0..<4 { b[at + s] = UInt8.random(in: 0...255, using: &rng) }
            }
        case 5:   // random garbage that looks like a sequence header
            b = (0..<Int.random(in: 0...4096, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if b.count >= 4 { b[3] |= 0x80 }
        case 6:   // duplicate a chunk
            if b.count >= 8 {
                let a = Int.random(in: 0..<(b.count / 4), using: &rng) * 4
                let len = min(Int.random(in: 1...64, using: &rng) * 4, b.count - a)
                b.insert(contentsOf: Array(b[a..<(a + len)]), at: Int.random(in: 0...(b.count / 4), using: &rng) * 4)
            }
        case 7:   // zero a range (short blocks, the hang case)
            if b.count >= 8 {
                let a = Int.random(in: 0..<b.count, using: &rng)
                let end = min(b.count, a + Int.random(in: 1...256, using: &rng))
                for i in a..<end { b[i] = 0 }
            }
        case 8:   // trailing words
            b += (0..<Int.random(in: 1...32, using: &rng) * 4).map { _ in UInt8.random(in: 0...255, using: &rng) }
        default:  // untouched
            break
        }
        return b
    }

    // MARK: - Parser fuzz

    func testParserSurvivesTenThousandMutatedFramesWithinTimeBounds() throws {
        let format = PyroWaveStreamFormat(width: 320, height: 180, chroma444: false, bitDepth: 8)
        let valid = [UInt8](try encodeFrame(width: 320, height: 180, budget: 40_000))
        var rng = SplitMix64(state: 0xC0FFEE)
        var successes = 0
        var worst = 0.0
        let start = CACurrentMediaTime()

        for i in 0..<10_000 {
            let input = mutate(valid, rng: &rng)
            let t = CACurrentMediaTime()
            let result = input.withUnsafeBytes { PyroWaveRecordParser.parse($0, expected: format) }
            let dt = CACurrentMediaTime() - t
            worst = max(worst, dt)
            XCTAssertLessThan(dt, 0.1, "parse \(i) took \(dt) s")
            if case .success(let f) = result {
                successes += 1
                for r in f.records {
                    XCTAssertGreaterThanOrEqual(r.lowerBound, 0)
                    XCTAssertLessThanOrEqual(r.upperBound, input.count)
                    XCTAssertEqual(r.lowerBound % 4, 0)
                    XCTAssertEqual(r.count % 4, 0)
                }
            }
        }
        let total = CACurrentMediaTime() - start
        XCTAssertLessThan(total, 20, "10k parses must finish in bounded time")
        XCTAssertGreaterThan(successes, 100, "the mutator must also produce frames the parser accepts")
        // Random truncation and garbage dominate, so not everything may be accepted either.
        XCTAssertLessThan(successes, 10_000)
        DebugFileLog.write("D7 parser fuzz: 10000 frames in \(String(format: "%.2f", total)) s, "
                         + "worst \(String(format: "%.3f", worst * 1000)) ms, accepted \(successes)")
    }

    /// The frames the Swift parser accepts still reach the C parser and the GPU. None of them may
    /// crash, hang or leave the decoder unable to decode the next valid frame.
    func testDecoderSurvivesMutatedFramesAndStillDecodesAValidOne() async throws {
        let (w, h) = (320, 180)
        let valid = try encodeFrame(width: w, height: h, budget: 40_000)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: w, height: h, chroma444: false, bitDepth: 8)
        let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
        var rng = SplitMix64(state: 0xBADC0DE)

        let before = CACurrentMediaTime()
        for i in 0..<400 {
            let bytes = mutate([UInt8](valid), rng: &rng)
            decoder.submit(frame: Data(bytes), pts: CMTime(value: Int64(i), timescale: 60))
            await settle(decoder)   // one at a time: no mailbox replacement muddies the accounting
        }
        let elapsed = CACurrentMediaTime() - before
        let c = decoder.counterSnapshot
        XCTAssertEqual(outcomes(c), c.submitted, "every frame must reach a terminal outcome: \(c)")
        XCTAssertLessThan(elapsed, 30)

        let decodedBefore = c.decoded
        decoder.submit(frame: valid, pts: CMTime(value: 999, timescale: 60))
        await settle(decoder)
        XCTAssertEqual(decoder.counterSnapshot.decoded, decodedBefore + 1, "decoder must recover: \(decoder.counterSnapshot)")
        DebugFileLog.write("D7 decoder fuzz: 400 frames in \(String(format: "%.2f", elapsed)) s, \(c)")
    }

    // MARK: - Resolution sanity

    func testFormatValidationRejectsOddAndOversizeDimensions() {
        XCTAssertNil(PyroWaveStreamFormat(width: 3024, height: 1890, chroma444: false, bitDepth: 8).validationFailure)
        XCTAssertNotNil(PyroWaveStreamFormat(width: 3023, height: 1890, chroma444: false, bitDepth: 8).validationFailure)
        XCTAssertNotNil(PyroWaveStreamFormat(width: 3024, height: 1889, chroma444: false, bitDepth: 8).validationFailure)
        XCTAssertNil(PyroWaveStreamFormat(width: 1921, height: 1081, chroma444: true, bitDepth: 8).validationFailure,
                     "4:4:4 has no even-size requirement")
        XCTAssertNotNil(PyroWaveStreamFormat(width: 0, height: 1080, chroma444: false, bitDepth: 8).validationFailure)
        XCTAssertNotNil(PyroWaveStreamFormat(width: 20000, height: 1080, chroma444: false, bitDepth: 8).validationFailure)
        XCTAssertNotNil(PyroWaveStreamFormat(width: 1920, height: 1080, chroma444: false, bitDepth: 12).validationFailure)
    }

    func testDecoderRefusesOddDimensions() throws {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertThrowsError(try PyroWaveDecoder(
            device: device, format: PyroWaveStreamFormat(width: 641, height: 360, chroma444: false, bitDepth: 8)))
    }

    // MARK: - Lifecycle

    func testDecoderLifecycleTwentyCyclesLeaksNothing() async throws {
        let (w, h) = (320, 180)
        let frame = try encodeFrame(width: w, height: h, budget: 40_000)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: w, height: h, chroma444: false, bitDepth: 8)

        weak var weakDecoder: PyroWaveDecoder?
        weak var weakPool: PlanarFramePool?
        weak var weakTexture: AnyObject?
        var footprintAfter5 = 0.0
        var footprint: [Double] = []

        for cycle in 1...20 {
            do {
                let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .private)
                let box = FrameBox()
                decoder.onFrameDecoded = { f, _ in box.add(f) }
                for i in 0..<5 {
                    decoder.submit(frame: frame, pts: CMTime(value: Int64(i), timescale: 60))
                    await settle(decoder)
                }
                XCTAssertGreaterThanOrEqual(decoder.counterSnapshot.decoded, 1, "cycle \(cycle)")
                decoder.onFrameDecoded = nil
                weakDecoder = decoder
                weakPool = decoder.framePool
                weakTexture = box.first()?.y as AnyObject?
                box.removeAll()
            }
            // Completed handlers retain the decoder until Metal has run them.
            let end = Date().addingTimeInterval(3)
            while (weakDecoder != nil || weakPool != nil || weakTexture != nil) && Date() < end {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNil(weakDecoder, "decoder leaked in cycle \(cycle)")
            XCTAssertNil(weakPool, "frame pool leaked in cycle \(cycle)")
            XCTAssertNil(weakTexture, "texture leaked in cycle \(cycle)")
            footprint.append(physFootprintMB())
            if cycle == 5 { footprintAfter5 = footprint.last! }
        }
        let growth = footprint.last! - footprintAfter5
        DebugFileLog.write("D7 decoder lifecycle: footprint MB after 5 cycles \(String(format: "%.1f", footprintAfter5)), "
                         + "after 20 \(String(format: "%.1f", footprint.last!))")
        XCTAssertLessThan(growth, 48, "footprint grew \(growth) MB over cycles 6 to 20")
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [PlanarVideoFrame] = []
        func add(_ f: PlanarVideoFrame) { lock.withLock { frames.append(f) } }
        func first() -> PlanarVideoFrame? { lock.withLock { frames.first } }
        func removeAll() { lock.withLock { frames.removeAll() } }
    }

    func testReceiverStartStopTwentyTimesLeaksNoSocketsOrObjects() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        let format = PyroWaveStreamFormat(width: 320, height: 180, chroma444: false, bitDepth: 8)
        // One-time lazy setup (shared device, shader library, first command queue) opens a few
        // descriptors that stay open for the process. Do it before measuring so only per-cycle
        // growth counts.
        _ = try PyroWaveDevice.shared(for: device)
        _ = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
        let fdsBefore = openFileDescriptors()
        weak var weakReceiver: RTPVideoReceiver?

        for cycle in 1...20 {
            let decoder = try PyroWaveDecoder(device: device, format: format, storageMode: .shared)
            let server = socket(AF_INET, SOCK_DGRAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) }
            }
            let serverPort = UInt16(bigEndian: bound.sin_port)

            let receiver = RTPVideoReceiver(decoder: VideoDecoder(), packetSize: packetSize, videoCodec: .pyrowave,
                                            streamFps: 60, pyroWaveDecoder: decoder)
            try await receiver.start(host: "127.0.0.1", serverPort: serverPort, localPort: 0,
                                     pingPayload: "0123456789ABCDEF")
            weakReceiver = receiver
            receiver.stop()
            close(server)
            XCTAssertGreaterThan(cycle, 0)
        }

        // The receive thread closes its socket after the shutdown wakeup; give it a moment.
        let end = Date().addingTimeInterval(3)
        while openFileDescriptors() > fdsBefore + 2 && Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertLessThanOrEqual(openFileDescriptors(), fdsBefore + 2, "sockets leaked across 20 start/stop cycles")
        let gone = Date().addingTimeInterval(3)
        while weakReceiver != nil && Date() < gone { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(weakReceiver, "receiver still referenced after stop")
    }

    // MARK: - Per-frame CPU profile

    /// Streams synthetic 3024x1890 frames at 60 fps (budget 604 KB, about 290 Mbps) over loopback
    /// UDP through the real receiver, queue and decoder, and writes where the time goes.
    ///
    /// Debug numbers are inflated because the vendored C++ is built -O0 there. For Release numbers:
    ///   xcodebuild -scheme ChloroFrame -configuration Release ENABLE_TESTABILITY=YES \
    ///     -only-testing:ChloroFrameTests/PyroWaveHardeningTests/testProfile3024x1890 test
    /// The report goes to $PYROWAVE_PROFILE_OUT or /tmp/chloroframe-pyrowave-profile.txt, so
    /// it needs no logging in the app.
    func testProfile3024x1890() async throws {
        let (w, h) = (3024, 1890)
        let frame = try encodeFrame(width: w, height: h, budget: 604_000)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = PyroWaveStreamFormat(width: w, height: h, chroma444: false, bitDepth: 8)
        let decoder = try PyroWaveDecoder(device: device, format: format)
        decoder.onFrameDecoded = { _, _ in }

        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sender, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sender, $0, &blen) }
        }
        let serverPort = UInt16(bigEndian: bound.sin_port)

        // Reserve a local port for the receiver.
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        var paddr = addr
        paddr.sin_port = 0
        _ = withUnsafePointer(to: &paddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var pb = sockaddr_in()
        var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &pb) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &plen) }
        }
        let localPort = UInt16(bigEndian: pb.sin_port)
        close(probe)

        let receiver = RTPVideoReceiver(decoder: VideoDecoder(), packetSize: packetSize, videoCodec: .pyrowave,
                                        streamFps: 60, pyroWaveDecoder: decoder)
        try await receiver.start(host: "127.0.0.1", serverPort: serverPort, localPort: localPort,
                                 pingPayload: "0123456789ABCDEF")
        defer { receiver.stop(); close(sender) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = localPort.bigEndian
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")

        let payload = packetSize - 16
        var seq: UInt16 = 0
        func send(frameIndex: UInt32) {
            var last = (frame.count + 8) % payload
            if last == 0 { last = payload }
            var stream = [UInt8]([0x01, 0, 0, 2, UInt8(last & 0xFF), UInt8(last >> 8), 0, 0]) + [UInt8](frame)
            let count = (stream.count + payload - 1) / payload
            stream += [UInt8](repeating: 0, count: count * payload - stream.count)
            let ts = frameIndex &* 1500
            for i in 0..<count {
                var d = [UInt8](repeating: 0, count: 32)
                d[0] = 0x90
                d[2] = UInt8(seq >> 8); d[3] = UInt8(seq & 0xFF)
                seq &+= 1
                for s in 0..<4 { d[4 + s] = UInt8((ts >> UInt32(24 - 8 * s)) & 0xFF) }
                for s in 0..<4 { d[16 + 4 + s] = UInt8((frameIndex >> UInt32(8 * s)) & 0xFF) }
                d[16 + 8] = i == 0 ? 0x04 : (i == count - 1 ? 0x02 : 0x01)
                let fecInfo = UInt32(count) << 22 | UInt32(i) << 12
                for s in 0..<4 { d[16 + 12 + s] = UInt8((fecInfo >> UInt32(8 * s)) & 0xFF) }
                d += stream[(i * payload)..<((i + 1) * payload)]
                _ = d.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(sender, raw.baseAddress, raw.count, 0, $0,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                // About 440 datagrams a frame: yield briefly every few so loopback is not a wall.
                if i % 32 == 31 { usleep(20) }
            }
        }

        let interval = 1.0 / 60.0
        var index: UInt32 = 1
        var next = CACurrentMediaTime()
        for _ in 0..<30 {                                  // warm-up, discarded
            send(frameIndex: index); index += 1
            next += interval
            let wait = next - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        await settle(decoder)
        _ = decoder.takeStageWindow()
        let base = decoder.counterSnapshot

        let measured = 300
        for _ in 0..<measured {
            send(frameIndex: index); index += 1
            next += interval
            let wait = next - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        await settle(decoder)
        let st = decoder.takeStageWindow()
        let c = decoder.counterSnapshot

        // Copy cost on this machine, for the "do the copies matter" question.
        let slice = [UInt8](repeating: 0x5A, count: payload)
        var assembly: [UInt8] = []
        assembly.reserveCapacity(frame.count + 8 + payload)
        var appendTotal = 0.0
        for _ in 0..<100 {
            assembly.removeAll(keepingCapacity: true)
            let t = CACurrentMediaTime()
            for _ in 0..<(frame.count / payload + 1) { assembly.append(contentsOf: slice) }
            appendTotal += CACurrentMediaTime() - t
        }
        var dataTotal = 0.0
        for _ in 0..<100 {
            let t = CACurrentMediaTime()
            let d = assembly.withUnsafeBufferPointer { Data(buffer: $0) }
            dataTotal += CACurrentMediaTime() - t
            XCTAssertEqual(d.count, assembly.count)
        }

        func f(_ s: StageStat) -> String { String(format: "avg %6.3f ms  max %7.3f ms  n=%d", s.avg, s.max, s.count) }
        #if DEBUG
        let config = "Debug (vendored C++ is -O0)"
        #else
        let config = "Release"
        #endif
        let report = """
        PyroWave per-frame profile, \(w)x\(h) @60, \(frame.count) byte frames, build: \(config)
        frames sent \(measured), decoded \(c.decoded - base.decoded), replaced \(c.mailboxReplaced - base.mailboxReplaced), \
        rejects parse \(c.parseRejects) push \(c.pushRejects) incomplete \(c.incomplete) pool \(c.poolExhausted) gpu \(c.gpuFailures)
        receive thread:
          slowest addPacket per frame  \(f(st.rxPacket))
          trim copy Data(buffer:)      \(f(st.rxTrimCopy))
        decode queue:
          submit interval              \(f(st.gap))
          queue wait                   \(f(st.queueWait))
          parse                        \(f(st.parse))
          push (clear+C push+ready)    \(f(st.push))
          encode (acquire+cmdbuf+commit) \(f(st.encode))
        GPU:
          commit to gpuStart           \(f(st.commitToGPU))
          gpu execution                \(f(st.gpu))
          gpuEnd to handler            \(f(st.completionLag))
          submit to handler (total)    \(f(st.total))
        mailbox replacements: burst(<\(PyroWaveStageTimes.burstGapMs) ms gap) \(st.replacedBurst), \
        while decode queue busy \(st.replacedWhileProcessing), while job waiting for queue thread \(st.replacedWhileWaiting)
        micro-benchmark, \(frame.count) bytes:
          frameAssembly.append, \(frame.count / payload + 1) slices  avg \(String(format: "%.3f", appendTotal / 100 * 1000)) ms
          Data(buffer:)                 avg \(String(format: "%.3f", dataTotal / 100 * 1000)) ms
        """
        let out = ProcessInfo.processInfo.environment["PYROWAVE_PROFILE_OUT"] ?? "/tmp/chloroframe-pyrowave-profile.txt"
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        XCTContext.runActivity(named: "PyroWave profile") { activity in
            let a = XCTAttachment(string: report)
            a.lifetime = .keepAlways
            activity.add(a)
        }

        XCTAssertEqual(c.parseRejects + c.pushRejects + c.incomplete + c.poolExhausted + c.gpuFailures, 0, report)
        XCTAssertGreaterThan(c.decoded - base.decoded, measured / 2, report)
    }
}

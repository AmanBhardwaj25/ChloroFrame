//
//  PyroWaveRoundTripTests.swift
//  ChloroFrameTests
//
//  Local GPU round trip (gate G1): encode a synthetic frame with the vendored
//  encoder, run the bitstream through PyroWaveDecoder, and compare against the
//  source. No host involved. Timing lines are printed with the prefix "G1".
//

import XCTest
import CoreGraphics
import CoreMedia
import Metal
@testable import ChloroFrame

final class PyroWaveRoundTripTests: XCTestCase {

    // MARK: - Synthetic image

    private struct Image {
        let width: Int
        let height: Int
        var y: [UInt8]
        var cb: [UInt8]
        var cr: [UInt8]
    }

    /// Luma gradient, a checkerboard region, and a seeded pseudo-random patch.
    /// Chroma is a pair of smooth gradients.
    private func makeImage(width: Int, height: Int, chroma444: Bool = false, dense: Bool = false) -> Image {
        if dense {
            // Noise everywhere: forces the encoder to spend its whole byte budget, so the
            // decode timing reflects a full payload rather than an easy synthetic frame.
            var s: UInt64 = 0xD1B5_4A32_D192_ED03
            func next() -> UInt8 {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17
                return UInt8(truncatingIfNeeded: s >> 24)
            }
            let cw = chroma444 ? width : width / 2
            let ch = chroma444 ? height : height / 2
            return Image(width: width, height: height,
                         y: (0..<width * height).map { _ in next() },
                         cb: (0..<cw * ch).map { _ in next() },
                         cr: (0..<cw * ch).map { _ in next() })
        }
        var y = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                var v = (col * 160) / width + (row * 80) / height + 16
                if col >= width / 8, col < width * 3 / 8, row >= height / 8, row < height * 3 / 8 {
                    let on = ((col / 16) + (row / 16)) & 1 == 0
                    v = on ? 215 : 40
                }
                y[row * width + col] = UInt8(min(v, 255))
            }
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let px = width * 5 / 8, py = height * 5 / 8
        for row in py..<min(py + 64, height) {
            for col in px..<min(px + 64, width) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                y[row * width + col] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }

        let cw = chroma444 ? width : width / 2
        let ch = chroma444 ? height : height / 2
        var cb = [UInt8](repeating: 0, count: cw * ch)
        var cr = [UInt8](repeating: 0, count: cw * ch)
        for row in 0..<ch {
            for col in 0..<cw {
                cb[row * cw + col] = UInt8(64 + (col * 128) / cw)
                cr[row * cw + col] = UInt8(64 + (row * 128) / ch)
            }
        }
        return Image(width: width, height: height, y: y, cb: cb, cr: cr)
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count)
        var sum: Double = 0
        for i in 0..<a.count {
            let d = Double(Int(a[i]) - Int(b[i]))
            sum += d * d
        }
        let mse = sum / Double(a.count)
        return mse == 0 ? .infinity : 10 * log10(255.0 * 255.0 / mse)
    }

    // MARK: - Bitstream helpers

    private func paddingRecord(words n: Int) -> Data {
        var d = Data()
        for w in [UInt32(0xFFFF_FFFF), UInt32(n)] {
            withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(Data(count: n * 4))
        return d
    }

    /// Concatenates packets into a record frame, with a padding record between packets
    /// (cycling 0, 3, 1 words) to exercise the parser.
    private func recordFrame(from packets: [Data], padding: Bool = true) -> Data {
        var out = Data()
        let sizes = [0, 3, 1]
        for (i, p) in packets.enumerated() {
            out.append(p)
            if padding, i + 1 < packets.count { out.append(paddingRecord(words: sizes[i % 3])) }
        }
        return out
    }

    /// Prints a measurement line and, when PYROWAVE_G1_LOG names a file (pass it to
    /// xcodebuild as TEST_RUNNER_PYROWAVE_G1_LOG), appends it there too.
    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["PYROWAVE_G1_LOG"],
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Decode harness

    private final class Harness {
        let decoder: PyroWaveDecoder
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var frame: PlanarVideoFrame?
        private var gpuMs = 0.0

        init(device: MTLDevice, width: Int, height: Int, chroma444: Bool = false, bitDepth: Int = 8,
             color: PlanarColorParams? = nil) throws {
            decoder = try PyroWaveDecoder(
                device: device,
                format: PyroWaveStreamFormat(width: width, height: height, chroma444: chroma444, bitDepth: bitDepth),
                storageMode: .shared, color: color)
            decoder.onGPUTime = { [weak self] ms in self?.lock.withLock { self?.gpuMs = ms } }
            decoder.onFrameDecoded = { [weak self] f, _ in
                self?.lock.withLock { self?.frame = f }
                self?.semaphore.signal()
            }
        }

        /// Submits one frame and waits for the completion handler. Returns nil on timeout
        /// (the frame was dropped).
        func decode(_ data: Data, timeout: TimeInterval = 5) -> (frame: PlanarVideoFrame, gpuMs: Double, e2eMs: Double)? {
            let start = CACurrentMediaTime()
            decoder.submit(frame: data, pts: .zero)
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            let e2e = (CACurrentMediaTime() - start) * 1000
            return lock.withLock { frame.map { ($0, gpuMs, e2e) } }
        }
    }

    private func readback(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(&bytes, bytesPerRow: texture.width,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    /// Reads an R16 plane back as normalized floats (`code16 / 65535`).
    private func readbackNormalized16(_ texture: MTLTexture) -> [Float] {
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(&raw, bytesPerRow: texture.width * 2,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return raw.map { Float($0) / 65535 }
    }

    private func requireDevice() throws -> MTLDevice {
        try XCTSkipUnless(VideoCapabilities.supportsPyroWave, "PyroWave needs an Apple7+ GPU")
        return try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    // MARK: - Round trip + timing

    /// Per-frame budget for a target wire rate at 60 fps, matching the plan's example
    /// (250 Mbps at 60 fps is about 520 KB).
    private func budget(mbpsAt60: Double) -> Int { Int(mbpsAt60 * 1_000_000 / 8 / 60) }

    private func roundTrip(label: String, width: Int, height: Int, mbpsAt60: Double,
                           chroma444: Bool = false, dense: Bool = false, minLumaPSNR: Double = 35,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let device = try requireDevice()
        let shared = try PyroWaveDevice.shared(for: device)
        let image = makeImage(width: width, height: height, chroma444: chroma444, dense: dense)

        let encoder = try PyroWaveEncoder(device: shared, width: width, height: height, chroma444: chroma444)
        let maxBytes = budget(mbpsAt60: mbpsAt60)
        let packets = try encoder.encode(y: image.y, cb: image.cb, cr: image.cr, maximumBitstreamSize: maxBytes)
        let frame = recordFrame(from: packets)

        let harness = try Harness(device: device, width: width, height: height, chroma444: chroma444)

        // Correctness, one decode, then compare against the source.
        let first = try XCTUnwrap(harness.decode(frame), "\(label): decode timed out or was dropped", file: file, line: line)
        let yPSNR = psnr(readback(first.frame.y), image.y)
        let cbPSNR = psnr(readback(first.frame.cb), image.cb)
        let crPSNR = psnr(readback(first.frame.cr), image.cr)

        // Timing: 10 warm-ups, then 100 measured decodes, one at a time.
        for _ in 0..<10 { _ = harness.decode(frame) }
        var gpu: [Double] = []
        var e2e: [Double] = []
        for _ in 0..<100 {
            let r = try XCTUnwrap(harness.decode(frame), file: file, line: line)
            gpu.append(r.gpuMs)
            e2e.append(r.e2eMs)
        }
        let avgGPU = gpu.reduce(0, +) / Double(gpu.count)
        let maxGPU = gpu.max() ?? 0
        let avgE2E = e2e.reduce(0, +) / Double(e2e.count)

        report(String(format: "G1 %@ %dx%d %@: bytes=%d packets=%d PSNR Y=%.2f Cb=%.2f Cr=%.2f dB, GPU decode avg=%.3f max=%.3f ms, submit-to-complete avg=%.3f ms",
                     label, width, height, chroma444 ? "4:4:4" : "4:2:0",
                     packets.reduce(0) { $0 + $1.count }, packets.count,
                     yPSNR, cbPSNR, crPSNR, avgGPU, maxGPU, avgE2E))

        XCTAssertGreaterThanOrEqual(yPSNR, minLumaPSNR, "\(label) luma PSNR", file: file, line: line)
        // Chroma plane geometry follows the negotiated profile (D8).
        let expectedChromaWidth = chroma444 ? width : width / 2
        let expectedChromaHeight = chroma444 ? height : height / 2
        XCTAssertEqual(first.frame.cb.width, expectedChromaWidth, "\(label) Cb width", file: file, line: line)
        XCTAssertEqual(first.frame.cb.height, expectedChromaHeight, "\(label) Cb height", file: file, line: line)
        XCTAssertEqual(first.frame.cr.width, expectedChromaWidth, "\(label) Cr width", file: file, line: line)
        XCTAssertEqual(first.frame.cr.height, expectedChromaHeight, "\(label) Cr height", file: file, line: line)
        if !dense {
            XCTAssertGreaterThanOrEqual(cbPSNR, 30, "\(label) Cb PSNR", file: file, line: line)
            XCTAssertGreaterThanOrEqual(crPSNR, 30, "\(label) Cr PSNR", file: file, line: line)
        }
        XCTAssertLessThan(avgGPU, 4.0, "\(label): GPU decode is over the 4 ms stop line", file: file, line: line)

        let counters = harness.decoder.counterSnapshot
        XCTAssertEqual(counters.parseRejects, 0, file: file, line: line)
        XCTAssertEqual(counters.pushRejects, 0, file: file, line: line)
        XCTAssertEqual(counters.incomplete, 0, file: file, line: line)
        XCTAssertEqual(counters.gpuFailures, 0, file: file, line: line)
    }

    func testRoundTrip1080p() throws {
        try roundTrip(label: "1080p", width: 1920, height: 1080, mbpsAt60: 250)
    }

    func testRoundTrip1440p() throws {
        try roundTrip(label: "1440p", width: 2560, height: 1440, mbpsAt60: 290)
    }

    func testRoundTrip4K() throws {
        try roundTrip(label: "4K", width: 3840, height: 2160, mbpsAt60: 290)
    }

    func testRoundTripNativePixels() throws {
        let (w, h) = nativeSize(pixels: true)
        try roundTrip(label: "native-pixels", width: w, height: h, mbpsAt60: 290)
    }

    /// ChloroFrame streams at the screen's logical size by default (DisplayConfig.detect).
    func testRoundTripNativeLogical() throws {
        let (w, h) = nativeSize(pixels: false)
        try roundTrip(label: "native-logical", width: w, height: h, mbpsAt60: 250)
    }

    /// Full-budget payload. Timing is the point: white noise at about 1.1 bits per luma
    /// sample cannot score high (about 17 dB is the rate-distortion bound; unrelated
    /// noise scores about 7.8 dB), so the PSNR floor only guards against garbage output.
    func testRoundTrip1080pDenseNoiseFillsBudget() throws {
        try roundTrip(label: "1080p-dense", width: 1920, height: 1080, mbpsAt60: 250,
                      dense: true, minLumaPSNR: 10)
    }

    func testRoundTrip1080p444() throws {
        try roundTrip(label: "1080p-444", width: 1920, height: 1080, mbpsAt60: 290, chroma444: true)
    }

    /// D9: a 10-bit stream decodes into R16 planes and carries the 10-bit color setup. The
    /// vendored encoder only reads 8-bit planes and the bitstream carries no bit depth, so the
    /// source here is 8-bit content; the decoded R16 samples must equal `source / 255`
    /// (normalized as `code / (2^N - 1)`), not `source / 1023`.
    func testRoundTripTenBitDecodesToNormalizedR16() throws {
        for chroma444 in [false, true] {
            let device = try requireDevice()
            let shared = try PyroWaveDevice.shared(for: device)
            let (w, h) = (1280, 720)
            let image = makeImage(width: w, height: h, chroma444: chroma444)
            let encoder = try PyroWaveEncoder(device: shared, width: w, height: h, chroma444: chroma444)
            let packets = try encoder.encode(y: image.y, cb: image.cb, cr: image.cr,
                                             maximumBitstreamSize: budget(mbpsAt60: 250))
            let color = PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: true)
            let harness = try Harness(device: device, width: w, height: h, chroma444: chroma444,
                                      bitDepth: 10, color: color)
            let decoded = try XCTUnwrap(harness.decode(recordFrame(from: packets)))
            let frame = decoded.frame

            XCTAssertEqual(frame.y.pixelFormat, .r16Unorm)
            XCTAssertEqual(frame.cb.pixelFormat, .r16Unorm)
            XCTAssertEqual(frame.cr.pixelFormat, .r16Unorm)
            XCTAssertEqual(frame.color.bitDepth, 10)
            XCTAssertTrue(frame.color.isPQ)
            XCTAssertEqual(frame.color.matrix, .bt2020)
            XCTAssertEqual(frame.cb.width, chroma444 ? w : w / 2)

            func meanAbsError(_ got: [Float], _ want: [UInt8]) -> Double {
                var sum = 0.0
                for i in 0..<want.count { sum += Double(abs(got[i] - Float(want[i]) / 255)) }
                return sum / Double(want.count)
            }
            // Mean error under 1.5 codes of an 8-bit scale; /1023 scaling would be off by 4x.
            XCTAssertLessThan(meanAbsError(readbackNormalized16(frame.y), image.y), 1.5 / 255, "luma, chroma444=\(chroma444)")
            XCTAssertLessThan(meanAbsError(readbackNormalized16(frame.cb), image.cb), 3.0 / 255, "Cb, chroma444=\(chroma444)")
            XCTAssertLessThan(meanAbsError(readbackNormalized16(frame.cr), image.cr), 3.0 / 255, "Cr, chroma444=\(chroma444)")

            let counters = harness.decoder.counterSnapshot
            XCTAssertEqual(counters.parseRejects + counters.pushRejects + counters.incomplete + counters.gpuFailures, 0)
        }
    }

    /// D9: the host's HDR mode message flips the stamped color; frames already handed out keep theirs.
    func testSetColorAffectsOnlyLaterFrames() throws {
        let device = try requireDevice()
        let pq = PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: true)
        let sdr = PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: false)
        let pool = PlanarFramePool(device: device, width: 64, height: 64, chroma444: false, bitDepth: 10,
                                   maxFrames: 4, storageMode: .shared, color: pq)
        let first = try XCTUnwrap(pool.acquire())
        pool.color = sdr
        let second = try XCTUnwrap(pool.acquire())
        XCTAssertTrue(first.color.isPQ)
        XCTAssertFalse(second.color.isPQ)
        XCTAssertEqual(second.color.matrix, .bt2020, "10-bit SDR from encoderCscMode 4 is BT.2020")
        XCTAssertFalse(second.color.fullRange)
    }

    private func nativeSize(pixels: Bool) -> (Int, Int) {
        let id = CGMainDisplayID()
        var w = 3024, h = 1964   // M4 Pro 14-inch panel, used when no display is attached
        if let mode = CGDisplayCopyDisplayMode(id) {
            w = pixels ? mode.pixelWidth : mode.width
            h = pixels ? mode.pixelHeight : mode.height
        }
        return (w & ~1, h & ~1)
    }

    // MARK: - Missing block

    func testMissingBlockIsDroppedStrictAndBlursWhenForced() throws {
        let device = try requireDevice()
        let shared = try PyroWaveDevice.shared(for: device)
        let (width, height) = (1920, 1080)
        let image = makeImage(width: width, height: height)

        let encoder = try PyroWaveEncoder(device: shared, width: width, height: height, chroma444: false)
        let packets = try encoder.encode(y: image.y, cb: image.cb, cr: image.cr,
                                         maximumBitstreamSize: budget(mbpsAt60: 250))
        let full = recordFrame(from: packets, padding: false)

        // Drop one block record from the middle of the frame.
        let format = PyroWaveStreamFormat(width: width, height: height, chroma444: false, bitDepth: 8)
        let parsed = try full.withUnsafeBytes { try PyroWaveRecordParser.parse($0, expected: format).get() }
        XCTAssertGreaterThan(parsed.blockRecordCount, 10)
        XCTAssertEqual(parsed.blockRecordCount, parsed.totalBlocks)
        let victim = parsed.records[parsed.records.count / 2]
        var truncated = full
        truncated.removeSubrange(victim)

        let harness = try Harness(device: device, width: width, height: height)

        // Strict: incomplete frame is dropped, nothing is delivered.
        XCTAssertNil(harness.decode(truncated, timeout: 0.5))
        XCTAssertEqual(harness.decoder.counterSnapshot.incomplete, 1)

        // Forced: decodes, and the loss shows as local blur rather than a failure.
        harness.decoder.allowPartialFrames = true
        let forced = try XCTUnwrap(harness.decode(truncated))
        let yPSNR = psnr(readback(forced.frame.y), image.y)
        report(String(format: "G1 missing-block 1080p: luma PSNR %.2f dB with 1 of %d blocks dropped", yPSNR, parsed.totalBlocks))
        XCTAssertGreaterThanOrEqual(yPSNR, 30)
        XCTAssertEqual(harness.decoder.counterSnapshot.decoded, 1)
    }

    // MARK: - Rejects and pool

    func testGarbageFrameIsRejectedWithoutDelivery() throws {
        let device = try requireDevice()
        let harness = try Harness(device: device, width: 1920, height: 1080)

        // Zero words: an untrimmed frame reads as a short block (D2 documents this case).
        XCTAssertNil(harness.decode(Data(count: 64), timeout: 0.5))
        // Length-prefixed framing (bit 31 clear in the first word).
        XCTAssertNil(harness.decode(Data([3, 0, 0, 0, 0, 0, 0, 0]), timeout: 0.5))
        XCTAssertEqual(harness.decoder.counterSnapshot.parseRejects, 2)
        XCTAssertEqual(harness.decoder.counterSnapshot.decoded, 0)
    }

    func testPoolRecyclesAndRefusesPastCap() throws {
        let device = try requireDevice()
        let pool = PlanarFramePool(device: device, width: 64, height: 64, chroma444: false,
                                   bitDepth: 8, maxFrames: 2, storageMode: .shared)
        var a = pool.acquire()
        let b = pool.acquire()
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNil(pool.acquire(), "third frame must be refused at maxFrames = 2")
        XCTAssertEqual(pool.framesInUse, 2)

        let firstY = a?.y
        a = nil
        XCTAssertEqual(pool.framesInUse, 1)
        let c = pool.acquire()
        XCTAssertNotNil(c)
        XCTAssertTrue(c?.y === firstY, "released textures are reused")

        XCTAssertEqual(c?.y.pixelFormat, .r8Unorm)
        XCTAssertEqual(c?.cb.width, 32)
        XCTAssertEqual(c?.cb.height, 32)
        XCTAssertTrue(c?.y.usage.contains(.shaderWrite) ?? false)
    }
}

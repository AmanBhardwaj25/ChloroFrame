//
//  PyroWaveNegotiationTests.swift
//  ChloroFrameTests
//
//  design/pyrowave-implementation-plan.md D5: DESCRIBE detection, downgrade rules, the default
//  bitrate and the /serverinfo capability bits.
//

import XCTest
import CryptoKit
@testable import ChloroFrame

final class PyroWaveNegotiationTests: XCTestCase {

    // MARK: - DESCRIBE parsing (SDPInfo)

    private let hevcOnly =
        "v=0\r\ns=Sunshine\r\nt=0 0\r\nm=video 0 RTP/AVP 0\r\n" +
        "a=fmtp:98 sprop-parameter-sets=AAAAAU\r\na=control:streamid=video/0/0\r\n" +
        "m=audio 0 RTP/AVP 97\r\na=control:streamid=audio/0/0\r\n"

    private let withPyroWave =
        "v=0\r\ns=Sunshine\r\nt=0 0\r\nm=video 0 RTP/AVP 0\r\n" +
        "a=fmtp:98 sprop-parameter-sets=AAAAAU\r\n" +
        "a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:186f0393\r\n" +
        "a=control:streamid=video/0/0\r\n"

    private let withAV1AndPyroWave =
        "v=0\r\ns=Sunshine\r\nm=video 0 RTP/AVP 0\r\n" +
        "a=rtpmap:98 AV1/90000\r\n" +
        "a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:186f0393\r\n"

    func testNoPyroWaveInPlainDescribe() {
        let info = SDPInfo(hevcOnly)
        XCTAssertFalse(info.advertisesPyroWave)
        XCTAssertNil(info.pyroWaveBitstreamID)
        XCTAssertEqual(info.videoCodec, .hevc)
    }

    func testPyroWaveAndBitstreamIDAreDetected() {
        let info = SDPInfo(withPyroWave)
        XCTAssertTrue(info.advertisesPyroWave)
        XCTAssertEqual(info.pyroWaveBitstreamID, "186f0393")
        // videoCodec logic is unchanged by the new fields.
        XCTAssertEqual(info.videoCodec, .hevc)
    }

    func testBothAV1AndPyroWaveAreDetected() {
        let info = SDPInfo(withAV1AndPyroWave)
        XCTAssertEqual(info.videoCodec, .av1)
        XCTAssertTrue(info.advertisesPyroWave)
    }

    func testBitstreamIDWithTrailingCarriageReturnAndSpaces() {
        let info = SDPInfo("a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:186f0393 \r\n")
        XCTAssertEqual(info.pyroWaveBitstreamID, "186f0393")
        let lfOnly = SDPInfo("a=rtpmap:99 PYROWAVE/90000\na=x-ss-pyrowave.bitstream:186f0393\n")
        XCTAssertEqual(lfOnly.pyroWaveBitstreamID, "186f0393")
    }

    func testEmptyBitstreamIDIsNil() {
        let info = SDPInfo("a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:\r\n")
        XCTAssertTrue(info.advertisesPyroWave)
        XCTAssertNil(info.pyroWaveBitstreamID)
    }

    // MARK: - Downgrade rules

    private func request() -> StreamConfig {
        var c = StreamConfig()
        c.codec = .pyrowave
        c.bitrate = 220_000
        c.fallbackBitrateKbps = 80_000
        c.yuv444 = true
        return c
    }

    func testStaysPyroWaveWhenAdvertisedOnLocalRoute() {
        let o = PyroWaveNegotiation.resolve(config: request(), sdp: SDPInfo(withPyroWave), networkClass: .local)
        XCTAssertEqual(o.config.codec, .pyrowave)
        XCTAssertEqual(o.config.bitrate, 220_000)
        XCTAssertNil(o.downgradeReason)
        XCTAssertFalse(o.bitstreamMismatch)
    }

    func testDowngradesToHevcWhenNotAdvertised() {
        let o = PyroWaveNegotiation.resolve(config: request(), sdp: SDPInfo(hevcOnly), networkClass: .local)
        XCTAssertEqual(o.config.codec, .hevc)
        XCTAssertEqual(o.config.bitrate, 80_000)   // the non-PyroWave bitrate is restored
        XCTAssertFalse(o.config.yuv444)
        XCTAssertNotNil(o.downgradeReason)
    }

    func testDowngradesToHevcOnRemoteRoute() {
        let o = PyroWaveNegotiation.resolve(config: request(), sdp: SDPInfo(withPyroWave), networkClass: .remote)
        XCTAssertEqual(o.config.codec, .hevc)
        XCTAssertEqual(o.config.bitrate, 80_000)
        XCTAssertNotNil(o.downgradeReason)
    }

    func testDowngradeKeepsBitrateWithoutFallback() {
        var c = request()
        c.fallbackBitrateKbps = nil
        let o = PyroWaveNegotiation.resolve(config: c, sdp: SDPInfo(hevcOnly), networkClass: .local)
        XCTAssertEqual(o.config.codec, .hevc)
        XCTAssertEqual(o.config.bitrate, 220_000)
    }

    func testBitstreamMismatchWarnsAndContinues() {
        let other = SDPInfo("a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:deadbeef\r\n")
        let o = PyroWaveNegotiation.resolve(config: request(), sdp: other, networkClass: .local)
        XCTAssertEqual(o.config.codec, .pyrowave)
        XCTAssertTrue(o.bitstreamMismatch)
        XCTAssertNil(o.downgradeReason)
    }

    // MARK: - Default bitrate

    // MARK: - 4:4:4 choice (D8)

    func testChromaIs420WhenNotRequested() {
        let r = PyroWaveNegotiation.chooseChroma(userWants444: false, hostSupports444: true)
        XCTAssertFalse(r.use444)
        XCTAssertNil(r.fallbackReason)
    }

    func testChromaIs444WhenRequestedAndOffered() {
        let r = PyroWaveNegotiation.chooseChroma(userWants444: true, hostSupports444: true)
        XCTAssertTrue(r.use444)
        XCTAssertNil(r.fallbackReason)
    }

    func testChromaFallsBackTo420WhenHostLacks444() {
        let r = PyroWaveNegotiation.chooseChroma(userWants444: true, hostSupports444: false)
        XCTAssertFalse(r.use444)
        XCTAssertNotNil(r.fallbackReason)
    }

    func testStaysPyroWave444WhenAdvertisedOnLocalRoute() {
        var c = request()
        c.yuv444 = true
        let sdp = SDPInfo(withPyroWave)
        let o = PyroWaveNegotiation.resolve(config: c, sdp: sdp, networkClass: .local)
        XCTAssertNil(o.downgradeReason)
        XCTAssertTrue(o.config.yuv444)
    }

    func testPyroWave444BitrateDefaultIsOnePointOneFiveTimesLarger() {
        let base = PyroWaveBitrate.defaultKbps(width: 3024, height: 1890, fps: 60)
        let wide = PyroWaveBitrate.defaultKbps(width: 3024, height: 1890, fps: 60, yuv444: true)
        XCTAssertEqual(Double(wide), Double(base) * 1.15, accuracy: 1)
    }

    func testPyroWaveHDR10BitrateDefaultIsOnePointTwoTimesLarger() {
        let base = PyroWaveBitrate.defaultKbps(width: 3024, height: 1890, fps: 60)
        let hdr = PyroWaveBitrate.defaultKbps(width: 3024, height: 1890, fps: 60, hdr10: true)
        XCTAssertEqual(Double(hdr), Double(base) * 1.2, accuracy: 1)
        let both = PyroWaveBitrate.defaultKbps(width: 3024, height: 1890, fps: 60, hdr10: true, yuv444: true)
        XCTAssertEqual(Double(both), Double(base) * 1.2 * 1.15, accuracy: 1)
    }

    // MARK: - Profile choice (D8 and D9)

    private let m8 = ServerInfo.scmPyroWave
    private let m444 = ServerInfo.scmPyroWave444
    private let mHDR = ServerInfo.scmPyroWaveHDR10
    private let mHDR444 = ServerInfo.scmPyroWaveHDR10_444

    func testProfileIsEightBit420WhenNothingIsAsked() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: false, userWantsHDR: false,
                                                  hostSCM: m8 | m444 | mHDR | mHDR444)
        XCTAssertEqual(p, .init(chroma444: false, tenBit: false, fallbackReason: nil))
        XCTAssertEqual(p.label, "4:2:0 8-bit")
    }

    func testProfileHDR420() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: false, userWantsHDR: true, hostSCM: m8 | mHDR)
        XCTAssertEqual(p, .init(chroma444: false, tenBit: true, fallbackReason: nil))
    }

    func testProfileHDR444() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: true, userWantsHDR: true,
                                                  hostSCM: m8 | m444 | mHDR | mHDR444)
        XCTAssertEqual(p, .init(chroma444: true, tenBit: true, fallbackReason: nil))
        XCTAssertEqual(p.label, "4:4:4 10-bit")
    }

    func testProfileHDRKeepsHDRWhenHostLacksHDR444() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: true, userWantsHDR: true,
                                                  hostSCM: m8 | m444 | mHDR)
        XCTAssertTrue(p.tenBit)
        XCTAssertFalse(p.chroma444)
        XCTAssertNotNil(p.fallbackReason)
    }

    func testProfileFallsBackToEightBitSDRWhenHostHasNoTenBit() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: true, userWantsHDR: true, hostSCM: m8 | m444)
        XCTAssertFalse(p.tenBit)
        XCTAssertTrue(p.chroma444, "the 4:4:4 request is still honored at 8-bit")
        XCTAssertTrue(p.fallbackReason?.contains("8-bit SDR") ?? false)

        let q = PyroWaveNegotiation.chooseProfile(userWants444: false, userWantsHDR: true, hostSCM: m8)
        XCTAssertEqual(q.label, "4:2:0 8-bit")
        XCTAssertNotNil(q.fallbackReason)
    }

    func testProfileNeverGoesTenBitUnasked() {
        let p = PyroWaveNegotiation.chooseProfile(userWants444: true, userWantsHDR: false,
                                                  hostSCM: m8 | m444 | mHDR | mHDR444)
        XCTAssertEqual(p, .init(chroma444: true, tenBit: false, fallbackReason: nil))
    }

    func testProfileMatchesChooseChromaForEightBit() {
        for want in [false, true] {
            for has in [false, true] {
                let scm = m8 | (has ? m444 : 0)
                let p = PyroWaveNegotiation.chooseProfile(userWants444: want, userWantsHDR: false, hostSCM: scm)
                let c = PyroWaveNegotiation.chooseChroma(userWants444: want, hostSupports444: has)
                XCTAssertEqual(p.chroma444, c.use444)
                XCTAssertEqual(p.fallbackReason, c.fallbackReason)
            }
        }
    }

    // MARK: - Host HDR mode message (0x010e)

    func testHdrModeMessageRoundTripsEncrypted() {
        let key = SymmetricKey(data: Data((0..<16).map { UInt8($0) }))
        for enabled in [true, false] {
            let wire = HostHdrModeMessage.encryptedPayload(enabled: enabled, seq: 0x0102_0304, key: key)
            XCTAssertFalse(wire.isEmpty)
            XCTAssertEqual(HostHdrModeMessage.parse(payload: wire, key: key), enabled)
        }
    }

    func testHdrModeMessageRejectsWrongKeyTamperingAndTruncation() {
        let key = SymmetricKey(data: Data((0..<16).map { UInt8($0) }))
        let other = SymmetricKey(data: Data((0..<16).map { UInt8($0 + 1) }))
        var wire = HostHdrModeMessage.encryptedPayload(enabled: true, seq: 7, key: key)
        XCTAssertNil(HostHdrModeMessage.parse(payload: wire, key: other))
        XCTAssertNil(HostHdrModeMessage.parse(payload: Array(wire.prefix(10)), key: key))
        XCTAssertNil(HostHdrModeMessage.parse(payload: [], key: key))
        wire[wire.count - 1] ^= 0xFF
        XCTAssertNil(HostHdrModeMessage.parse(payload: wire, key: key))
    }

    func testHdrModeMessagePlaintextAndOtherTypes() {
        XCTAssertEqual(HostHdrModeMessage.parse(payload: [0x0e, 0x01, 0x1d, 0x00, 0x01, 0, 0], key: nil), true)
        XCTAssertEqual(HostHdrModeMessage.parse(payload: [0x0e, 0x01, 0x1d, 0x00, 0x00, 0, 0], key: nil), false)
        // A different control type (here 0x0100, termination) is not an HDR message.
        XCTAssertNil(HostHdrModeMessage.parse(payload: [0x00, 0x01, 0x04, 0x00, 0x01, 0, 0], key: nil))
    }

    func testDefaultBitrateMatchesTheAuthorsGuide() {
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 1920, height: 1080, fps: 60), 220_000)
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 2560, height: 1440, fps: 120), 580_000)
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 3840, height: 2160, fps: 120, hdr10: true), 696_000)
    }

    func testDefaultBitrateAppliesFactorsAndClamps() {
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 1920, height: 1080, fps: 60, yuv444: true), 253_000)
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 1280, height: 720, fps: 10), 100_000)
        XCTAssertEqual(PyroWaveBitrate.defaultKbps(width: 7680, height: 4320, fps: 500, hdr10: true, yuv444: true), 2_000_000)
    }

    // MARK: - /serverinfo bits

    private func info(_ modes: Int) -> ServerInfo {
        ServerInfo(hostname: "h", gpuType: "g", serverUniqueId: "u", pairStatus: 1,
                   codecModeSupport: modes, currentGame: 0)
    }

    func testServerInfoPyroWaveBits() {
        XCTAssertEqual(ServerInfo.scmPyroWave, 0x00800000)
        XCTAssertEqual(ServerInfo.scmPyroWave444, 0x01000000)
        XCTAssertEqual(ServerInfo.scmPyroWaveHDR10, 0x02000000)
        XCTAssertEqual(ServerInfo.scmPyroWaveHDR10_444, 0x04000000)

        let none = info(ServerInfo.scmAV1Main8 | 0x1 | 0x100)
        XCTAssertFalse(none.supportsPyroWave420)
        XCTAssertFalse(none.supportsPyroWave444)

        let all = info(0x00800000 | 0x01000000 | 0x02000000 | 0x04000000)
        XCTAssertTrue(all.supportsPyroWave420)
        XCTAssertTrue(all.supportsPyroWave444)
        XCTAssertTrue(all.supportsPyroWaveHDR10)
        XCTAssertTrue(all.supportsPyroWaveHDR10_444)

        let only444 = info(0x01000000)
        XCTAssertFalse(only444.supportsPyroWave420)
        XCTAssertTrue(only444.supportsPyroWave444)
    }
}

//
//  PyroWaveNegotiationTests.swift
//  ChloroFrameTests
//
//  design/pyrowave-implementation-plan.md D5: DESCRIBE detection, downgrade rules, the default
//  bitrate and the /serverinfo capability bits.
//

import XCTest
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

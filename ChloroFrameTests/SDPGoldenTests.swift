//
//  SDPGoldenTests.swift
//  ChloroFrameTests
//
//  Byte-for-byte baselines of the ANNOUNCE SDP for H.264, HEVC and AV1, captured from the code
//  before any PyroWave change (design/pyrowave-implementation-plan.md D5, rule 2). These must
//  never change: PyroWave is additive and must not alter what existing codecs announce.
//

import XCTest
@testable import ChloroFrame

final class SDPGoldenTests: XCTestCase {

    private func config(_ width: Int, _ height: Int, _ fps: Int, _ bitrate: Int,
                        _ codec: VideoCodec, hdr: Bool) -> StreamConfig {
        var c = StreamConfig()
        c.width = width; c.height = height; c.fps = fps
        c.bitrate = bitrate; c.codec = codec; c.hdr = hdr
        return c
    }

    private func sdp(_ config: StreamConfig, _ networkClass: StreamNetworkClass, _ packetSize: Int) -> String {
        SDPBuilder.buildAnnounceSDP(
            serverHost: "192.168.1.50", videoLocalPort: 47998, config: config,
            networkClass: networkClass, videoPacketSize: packetSize
        )
    }

    private let golden_h264: String =
        "v=0\r\n" +
        "o=android 0 14 IN IPv4 192.168.1.50\r\n" +
        "s=NVIDIA Streaming Client\r\n" +
        "t=0 0\r\n" +
        "m=video 47998  \r\n" +
        "a=x-ml-general.featureFlags:3 \r\n" +
        "a=x-ss-general.encryptionEnabled:1 \r\n" +
        "a=x-ss-video[0].chromaSamplingType:0 \r\n" +
        "a=x-nv-video[0].clientViewportWd:1920 \r\n" +
        "a=x-nv-video[0].clientViewportHt:1080 \r\n" +
        "a=x-nv-video[0].maxFPS:60 \r\n" +
        "a=x-nv-video[0].packetSize:1392 \r\n" +
        "a=x-nv-video[0].rateControlMode:4 \r\n" +
        "a=x-nv-video[0].timeoutLengthMs:7000 \r\n" +
        "a=x-nv-video[0].framesWithInvalidRefThreshold:0 \r\n" +
        "a=x-nv-video[0].initialBitrateKbps:8000 \r\n" +
        "a=x-nv-video[0].initialPeakBitrateKbps:8000 \r\n" +
        "a=x-nv-vqos[0].bw.minimumBitrateKbps:8000 \r\n" +
        "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n" +
        "a=x-ml-video.configuredBitrateKbps:10000 \r\n" +
        "a=x-nv-vqos[0].fec.enable:1 \r\n" +
        "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000 \r\n" +
        "a=x-nv-vqos[0].qosTrafficType:5 \r\n" +
        "a=x-nv-aqos.qosTrafficType:4 \r\n" +
        "a=x-nv-general.featureFlags:135 \r\n" +
        "a=x-nv-general.useReliableUdp:13 \r\n" +
        "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n" +
        "a=x-nv-vqos[0].bllFec.enable:0 \r\n" +
        "a=x-nv-vqos[0].drc.enable:0 \r\n" +
        "a=x-nv-general.enableRecoveryMode:0 \r\n" +
        "a=x-nv-video[0].videoEncoderSlicesPerFrame:1 \r\n" +
        "a=x-nv-clientSupportHevc:0 \r\n" +
        "a=x-nv-vqos[0].bitStreamFormat:0 \r\n" +
        "a=x-nv-video[0].dynamicRangeMode:0 \r\n" +
        "a=x-nv-video[0].maxNumReferenceFrames:1 \r\n" +
        "a=x-nv-video[0].clientRefreshRateX100:6000 \r\n" +
        "a=x-nv-video[0].encoderCscMode:0 \r\n" +
        "a=x-nv-audio.surround.numChannels:2 \r\n" +
        "a=x-nv-audio.surround.channelMask:3 \r\n" +
        "a=x-nv-audio.surround.enable:0 \r\n" +
        "a=x-nv-audio.surround.AudioQuality:0 \r\n" +
        "a=x-nv-aqos.packetDuration:5 \r\n"

    func testGolden_h264() {
        let c = config(1920, 1080, 60, 10000, .h264, hdr: false)
        XCTAssertEqual(sdp(c, .local, 1392), golden_h264)
    }

    private let golden_hevc: String =
        "v=0\r\n" +
        "o=android 0 14 IN IPv4 192.168.1.50\r\n" +
        "s=NVIDIA Streaming Client\r\n" +
        "t=0 0\r\n" +
        "m=video 47998  \r\n" +
        "a=x-ml-general.featureFlags:3 \r\n" +
        "a=x-ss-general.encryptionEnabled:1 \r\n" +
        "a=x-ss-video[0].chromaSamplingType:0 \r\n" +
        "a=x-nv-video[0].clientViewportWd:2560 \r\n" +
        "a=x-nv-video[0].clientViewportHt:1440 \r\n" +
        "a=x-nv-video[0].maxFPS:120 \r\n" +
        "a=x-nv-video[0].packetSize:1392 \r\n" +
        "a=x-nv-video[0].rateControlMode:4 \r\n" +
        "a=x-nv-video[0].timeoutLengthMs:7000 \r\n" +
        "a=x-nv-video[0].framesWithInvalidRefThreshold:0 \r\n" +
        "a=x-nv-video[0].initialBitrateKbps:32000 \r\n" +
        "a=x-nv-video[0].initialPeakBitrateKbps:32000 \r\n" +
        "a=x-nv-vqos[0].bw.minimumBitrateKbps:32000 \r\n" +
        "a=x-nv-vqos[0].bw.maximumBitrateKbps:32000 \r\n" +
        "a=x-ml-video.configuredBitrateKbps:40000 \r\n" +
        "a=x-nv-vqos[0].fec.enable:1 \r\n" +
        "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000 \r\n" +
        "a=x-nv-vqos[0].qosTrafficType:5 \r\n" +
        "a=x-nv-aqos.qosTrafficType:4 \r\n" +
        "a=x-nv-general.featureFlags:135 \r\n" +
        "a=x-nv-general.useReliableUdp:13 \r\n" +
        "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n" +
        "a=x-nv-vqos[0].bllFec.enable:0 \r\n" +
        "a=x-nv-vqos[0].drc.enable:0 \r\n" +
        "a=x-nv-general.enableRecoveryMode:0 \r\n" +
        "a=x-nv-video[0].videoEncoderSlicesPerFrame:1 \r\n" +
        "a=x-nv-clientSupportHevc:1 \r\n" +
        "a=x-nv-vqos[0].bitStreamFormat:1 \r\n" +
        "a=x-nv-video[0].dynamicRangeMode:0 \r\n" +
        "a=x-nv-video[0].maxNumReferenceFrames:1 \r\n" +
        "a=x-nv-video[0].clientRefreshRateX100:12000 \r\n" +
        "a=x-nv-video[0].encoderCscMode:0 \r\n" +
        "a=x-nv-audio.surround.numChannels:2 \r\n" +
        "a=x-nv-audio.surround.channelMask:3 \r\n" +
        "a=x-nv-audio.surround.enable:0 \r\n" +
        "a=x-nv-audio.surround.AudioQuality:0 \r\n" +
        "a=x-nv-aqos.packetDuration:5 \r\n"

    func testGolden_hevc() {
        let c = config(2560, 1440, 120, 40000, .hevc, hdr: false)
        XCTAssertEqual(sdp(c, .local, 1392), golden_hevc)
    }

    private let golden_hevcHdrRemote: String =
        "v=0\r\n" +
        "o=android 0 14 IN IPv4 192.168.1.50\r\n" +
        "s=NVIDIA Streaming Client\r\n" +
        "t=0 0\r\n" +
        "m=video 47998  \r\n" +
        "a=x-ml-general.featureFlags:3 \r\n" +
        "a=x-ss-general.encryptionEnabled:1 \r\n" +
        "a=x-ss-video[0].chromaSamplingType:0 \r\n" +
        "a=x-nv-video[0].clientViewportWd:3840 \r\n" +
        "a=x-nv-video[0].clientViewportHt:2160 \r\n" +
        "a=x-nv-video[0].maxFPS:60 \r\n" +
        "a=x-nv-video[0].packetSize:1024 \r\n" +
        "a=x-nv-video[0].rateControlMode:4 \r\n" +
        "a=x-nv-video[0].timeoutLengthMs:7000 \r\n" +
        "a=x-nv-video[0].framesWithInvalidRefThreshold:0 \r\n" +
        "a=x-nv-video[0].initialBitrateKbps:39500 \r\n" +
        "a=x-nv-video[0].initialPeakBitrateKbps:39500 \r\n" +
        "a=x-nv-vqos[0].bw.minimumBitrateKbps:39500 \r\n" +
        "a=x-nv-vqos[0].bw.maximumBitrateKbps:39500 \r\n" +
        "a=x-ml-video.configuredBitrateKbps:50000 \r\n" +
        "a=x-nv-vqos[0].fec.enable:1 \r\n" +
        "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000 \r\n" +
        "a=x-nv-vqos[0].qosTrafficType:0 \r\n" +
        "a=x-nv-aqos.qosTrafficType:0 \r\n" +
        "a=x-nv-general.featureFlags:135 \r\n" +
        "a=x-nv-general.useReliableUdp:13 \r\n" +
        "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n" +
        "a=x-nv-vqos[0].bllFec.enable:0 \r\n" +
        "a=x-nv-vqos[0].drc.enable:0 \r\n" +
        "a=x-nv-general.enableRecoveryMode:0 \r\n" +
        "a=x-nv-video[0].videoEncoderSlicesPerFrame:1 \r\n" +
        "a=x-nv-clientSupportHevc:1 \r\n" +
        "a=x-nv-vqos[0].bitStreamFormat:1 \r\n" +
        "a=x-nv-video[0].dynamicRangeMode:1 \r\n" +
        "a=x-nv-video[0].maxNumReferenceFrames:1 \r\n" +
        "a=x-nv-video[0].clientRefreshRateX100:6000 \r\n" +
        "a=x-nv-video[0].encoderCscMode:4 \r\n" +
        "a=x-nv-audio.surround.numChannels:2 \r\n" +
        "a=x-nv-audio.surround.channelMask:3 \r\n" +
        "a=x-nv-audio.surround.enable:0 \r\n" +
        "a=x-nv-audio.surround.AudioQuality:0 \r\n" +
        "a=x-nv-aqos.packetDuration:5 \r\n"

    func testGolden_hevcHdrRemote() {
        let c = config(3840, 2160, 60, 50000, .hevc, hdr: true)
        XCTAssertEqual(sdp(c, .remote, 1024), golden_hevcHdrRemote)
    }

    private let golden_av1: String =
        "v=0\r\n" +
        "o=android 0 14 IN IPv4 192.168.1.50\r\n" +
        "s=NVIDIA Streaming Client\r\n" +
        "t=0 0\r\n" +
        "m=video 47998  \r\n" +
        "a=x-ml-general.featureFlags:3 \r\n" +
        "a=x-ss-general.encryptionEnabled:1 \r\n" +
        "a=x-ss-video[0].chromaSamplingType:0 \r\n" +
        "a=x-nv-video[0].clientViewportWd:1512 \r\n" +
        "a=x-nv-video[0].clientViewportHt:982 \r\n" +
        "a=x-nv-video[0].maxFPS:120 \r\n" +
        "a=x-nv-video[0].packetSize:1392 \r\n" +
        "a=x-nv-video[0].rateControlMode:4 \r\n" +
        "a=x-nv-video[0].timeoutLengthMs:7000 \r\n" +
        "a=x-nv-video[0].framesWithInvalidRefThreshold:0 \r\n" +
        "a=x-nv-video[0].initialBitrateKbps:64000 \r\n" +
        "a=x-nv-video[0].initialPeakBitrateKbps:64000 \r\n" +
        "a=x-nv-vqos[0].bw.minimumBitrateKbps:64000 \r\n" +
        "a=x-nv-vqos[0].bw.maximumBitrateKbps:64000 \r\n" +
        "a=x-ml-video.configuredBitrateKbps:80000 \r\n" +
        "a=x-nv-vqos[0].fec.enable:1 \r\n" +
        "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000 \r\n" +
        "a=x-nv-vqos[0].qosTrafficType:5 \r\n" +
        "a=x-nv-aqos.qosTrafficType:4 \r\n" +
        "a=x-nv-general.featureFlags:135 \r\n" +
        "a=x-nv-general.useReliableUdp:13 \r\n" +
        "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n" +
        "a=x-nv-vqos[0].bllFec.enable:0 \r\n" +
        "a=x-nv-vqos[0].drc.enable:0 \r\n" +
        "a=x-nv-general.enableRecoveryMode:0 \r\n" +
        "a=x-nv-video[0].videoEncoderSlicesPerFrame:1 \r\n" +
        "a=x-nv-clientSupportHevc:0 \r\n" +
        "a=x-nv-vqos[0].bitStreamFormat:2 \r\n" +
        "a=x-nv-video[0].dynamicRangeMode:0 \r\n" +
        "a=x-nv-video[0].maxNumReferenceFrames:1 \r\n" +
        "a=x-nv-video[0].clientRefreshRateX100:12000 \r\n" +
        "a=x-nv-video[0].encoderCscMode:0 \r\n" +
        "a=x-nv-audio.surround.numChannels:2 \r\n" +
        "a=x-nv-audio.surround.channelMask:3 \r\n" +
        "a=x-nv-audio.surround.enable:0 \r\n" +
        "a=x-nv-audio.surround.AudioQuality:0 \r\n" +
        "a=x-nv-aqos.packetDuration:5 \r\n"

    func testGolden_av1() {
        let c = config(1512, 982, 120, 80000, .av1, hdr: false)
        XCTAssertEqual(sdp(c, .local, 1392), golden_av1)
    }

    private let golden_av1Hdr: String =
        "v=0\r\n" +
        "o=android 0 14 IN IPv4 192.168.1.50\r\n" +
        "s=NVIDIA Streaming Client\r\n" +
        "t=0 0\r\n" +
        "m=video 47998  \r\n" +
        "a=x-ml-general.featureFlags:3 \r\n" +
        "a=x-ss-general.encryptionEnabled:1 \r\n" +
        "a=x-ss-video[0].chromaSamplingType:0 \r\n" +
        "a=x-nv-video[0].clientViewportWd:3024 \r\n" +
        "a=x-nv-video[0].clientViewportHt:1964 \r\n" +
        "a=x-nv-video[0].maxFPS:60 \r\n" +
        "a=x-nv-video[0].packetSize:1392 \r\n" +
        "a=x-nv-video[0].rateControlMode:4 \r\n" +
        "a=x-nv-video[0].timeoutLengthMs:7000 \r\n" +
        "a=x-nv-video[0].framesWithInvalidRefThreshold:0 \r\n" +
        "a=x-nv-video[0].initialBitrateKbps:48000 \r\n" +
        "a=x-nv-video[0].initialPeakBitrateKbps:48000 \r\n" +
        "a=x-nv-vqos[0].bw.minimumBitrateKbps:48000 \r\n" +
        "a=x-nv-vqos[0].bw.maximumBitrateKbps:48000 \r\n" +
        "a=x-ml-video.configuredBitrateKbps:60000 \r\n" +
        "a=x-nv-vqos[0].fec.enable:1 \r\n" +
        "a=x-nv-vqos[0].videoQualityScoreUpdateTime:5000 \r\n" +
        "a=x-nv-vqos[0].qosTrafficType:5 \r\n" +
        "a=x-nv-aqos.qosTrafficType:4 \r\n" +
        "a=x-nv-general.featureFlags:135 \r\n" +
        "a=x-nv-general.useReliableUdp:13 \r\n" +
        "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n" +
        "a=x-nv-vqos[0].bllFec.enable:0 \r\n" +
        "a=x-nv-vqos[0].drc.enable:0 \r\n" +
        "a=x-nv-general.enableRecoveryMode:0 \r\n" +
        "a=x-nv-video[0].videoEncoderSlicesPerFrame:1 \r\n" +
        "a=x-nv-clientSupportHevc:0 \r\n" +
        "a=x-nv-vqos[0].bitStreamFormat:2 \r\n" +
        "a=x-nv-video[0].dynamicRangeMode:1 \r\n" +
        "a=x-nv-video[0].maxNumReferenceFrames:1 \r\n" +
        "a=x-nv-video[0].clientRefreshRateX100:6000 \r\n" +
        "a=x-nv-video[0].encoderCscMode:4 \r\n" +
        "a=x-nv-audio.surround.numChannels:2 \r\n" +
        "a=x-nv-audio.surround.channelMask:3 \r\n" +
        "a=x-nv-audio.surround.enable:0 \r\n" +
        "a=x-nv-audio.surround.AudioQuality:0 \r\n" +
        "a=x-nv-aqos.packetDuration:5 \r\n"

    func testGolden_av1Hdr() {
        let c = config(3024, 1964, 60, 60000, .av1, hdr: true)
        XCTAssertEqual(sdp(c, .local, 1392), golden_av1Hdr)
    }
}

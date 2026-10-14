//
//  SDPBuilder.swift
//  ChloroFrame
//
//  Builds the ANNOUNCE SDP body, split out of RTSPClient so it can be unit-tested directly.
//  RTSPClient's own methods are private to that file (a fresh TCP connection per RTSP request),
//  so this needed to move to be reachable from a test target at all. Pure function: no I/O, no
//  RTSPClient state, just parameters to a string. See design/tailscale-connection-fix-plan.md
//  Phase 2.
//

import Foundation

nonisolated enum SDPBuilder {

    /// The `x-nv-video[0].encoderCscMode` value for a request. 4 = BT.2020 limited (HDR10),
    /// 2 = BT.709 limited (PyroWave SDR, decision Q3), 0 = BT.601 limited (every other SDR
    /// request). Shared with the PyroWave color setup so the shader matches what was asked for.
    static func encoderCscMode(codec: VideoCodec, hdr: Bool) -> Int {
        hdr ? 4 : (codec == .pyrowave ? 2 : 0)
    }

    /// Builds the client capability SDP sent in the ANNOUNCE body (after all SETUPs).
    /// Sunshine uses this to configure the encoder (resolution, FPS, bitrate, codec).
    /// Format mirrors Moonlight's SdpGenerator for AppVersion 7 / Sunshine.
    static func buildAnnounceSDP(
        serverHost: String,
        serverFamily: Int32 = AF_INET,
        videoLocalPort: UInt16,
        config: StreamConfig,
        encryptionEnabled: UInt32 = 1,
        networkClass: StreamNetworkClass,
        videoPacketSize: Int
    ) -> String {
        // Cap raised to 500 Mbps to allow experimenting with the custom bitrate field.
        var adjusted = min(Int(Double(config.bitrate) * 0.80), 500_000)
        // Remote streams (moonlight SdpGenerator.c): leave headroom for audio and control by
        // trimming 500 kbps off the video allocation. Local streams keep the full amount.
        if networkClass == .remote, adjusted > 500 {
            adjusted -= 500
        }
        let bitStreamFormat = switch config.codec {
            case .h264: 0
            case .hevc: 1
            case .av1:  2
            case .pyrowave: 3
        }
        let hevcFlag = config.codec == .hevc ? 1 : 0
        let refreshRateX100 = config.fps * 100
        // Remote streams use best-effort QoS marking; local streams request WMM voice/video
        // classes (moonlight SdpGenerator.c: qosTrafficType 5/4 for local, 0/0 for remote).
        let videoQos = networkClass == .local ? 5 : 0
        let audioQos = networkClass == .local ? 4 : 0

        // PyroWave (decision Q3): BT.709 limited for SDR, matching the planar shader. Every other
        // codec keeps the existing value (see gotcha 11 in the PyroWave plan).
        let isPyroWave = config.codec == .pyrowave
        let chromaSamplingType = isPyroWave && config.yuv444 ? 1 : 0
        let encoderCscMode = encoderCscMode(codec: config.codec, hdr: config.hdr)

        func a(_ name: String, _ value: Any) -> String { "a=\(name):\(value) \r\n" }

        // PyroWave only: the presence of pyrowaveAdaptiveFec selects record framing on the host;
        // pyrowaveFeatures 1 = FEC_RECORD_FRAMING. Empty (byte-identical SDP) for other codecs.
        let pyroWaveAttributes = isPyroWave
            ? a("x-ss-video[0].pyrowaveAdaptiveFec",     0) +
              a("x-ss-video[0].pyrowaveAdaptiveBitrate", 0) +
              a("x-ss-video[0].pyrowaveFeatures",        1)
            : ""

        // moonlight SdpGenerator.c fillSdpHeader: "IN IPv4|IPv6 <url-safe address>", where the
        // IPv6 form is bracketed (addrToUrlSafeString). HostAddress.urlHost matches that.
        let addressFamily = serverFamily == AF_INET6 ? "IPv6" : "IPv4"

        return
            "v=0\r\n" +
            "o=android 0 14 IN \(addressFamily) \(HostAddress.urlHost(serverHost))\r\n" +
            "s=NVIDIA Streaming Client\r\n" +
            "t=0 0\r\n" +
            "m=video \(videoLocalPort)  \r\n" +
            // Sunshine-specific feature negotiation
            a("x-ml-general.featureFlags",          3) +   // ML_FF_FEC_STATUS | ML_FF_SESSION_ID_V1
            a("x-ss-general.encryptionEnabled",     encryptionEnabled) +
            a("x-ss-video[0].chromaSamplingType",   chromaSamplingType) +   // 0 = YUV 4:2:0, 1 = 4:4:4 (PyroWave only)
            // Stream geometry + encoder settings
            a("x-nv-video[0].clientViewportWd",     config.width) +
            a("x-nv-video[0].clientViewportHt",     config.height) +
            a("x-nv-video[0].maxFPS",               config.fps) +
            a("x-nv-video[0].packetSize",           videoPacketSize) +
            a("x-nv-video[0].rateControlMode",      4) +
            a("x-nv-video[0].timeoutLengthMs",      7000) +
            a("x-nv-video[0].framesWithInvalidRefThreshold", 0) +
            // Bitrate
            a("x-nv-video[0].initialBitrateKbps",       adjusted) +
            a("x-nv-video[0].initialPeakBitrateKbps",   adjusted) +
            a("x-nv-vqos[0].bw.minimumBitrateKbps",     adjusted) +
            a("x-nv-vqos[0].bw.maximumBitrateKbps",     adjusted) +
            a("x-ml-video.configuredBitrateKbps",        config.bitrate) +
            // FEC + QoS
            a("x-nv-vqos[0].fec.enable",                    1) +
            a("x-nv-vqos[0].videoQualityScoreUpdateTime",   5000) +
            a("x-nv-vqos[0].qosTrafficType",                videoQos) +
            a("x-nv-aqos.qosTrafficType",                   audioQos) +
            // Gen5 / Sunshine transport flags
            a("x-nv-general.featureFlags",          135) +  // NVFF_BASE(7) | NVFF_RI_ENCRYPTION(128)
            a("x-nv-general.useReliableUdp",        13) +  // 13 = encrypted ENet control stream (APP_VERSION >= 7.1.431)
            a("x-nv-vqos[0].fec.minRequiredFecPackets", 2) +
            a("x-nv-vqos[0].bllFec.enable",         0) +
            a("x-nv-vqos[0].drc.enable",            0) +
            a("x-nv-general.enableRecoveryMode",    0) +
            // Codec selection
            a("x-nv-video[0].videoEncoderSlicesPerFrame", 1) +
            a("x-nv-clientSupportHevc",             hevcFlag) +
            a("x-nv-vqos[0].bitStreamFormat",       bitStreamFormat) +
            a("x-nv-video[0].dynamicRangeMode",     config.hdr ? 1 : 0) +
            a("x-nv-video[0].maxNumReferenceFrames", 1) +
            a("x-nv-video[0].clientRefreshRateX100", refreshRateX100) +
            a("x-nv-video[0].encoderCscMode",       encoderCscMode) +   // 4=BT.2020 limited (HDR10), 0=BT.601 limited (SDR), 2=BT.709 limited (PyroWave SDR)
            // Audio (stereo)
            a("x-nv-audio.surround.numChannels",    2) +
            a("x-nv-audio.surround.channelMask",    3) +
            a("x-nv-audio.surround.enable",         0) +
            a("x-nv-audio.surround.AudioQuality",   0) +
            a("x-nv-aqos.packetDuration",           5) +
            pyroWaveAttributes
    }
}

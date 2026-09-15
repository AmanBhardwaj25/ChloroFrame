//
//  SDPBuilderTests.swift
//  ChloroFrameTests
//
//  design/tailscale-connection-fix-plan.md Phase 2 (QoS marking, bitrate trim, packet size)
//  and Phase 3 (the SDP "o=" line's IN IPv4/IPv6 + bracketed-address choice), section 6.1.
//

import XCTest
@testable import ChloroFrame

final class SDPBuilderTests: XCTestCase {

    private func attribute(_ name: String, in sdp: String) -> String? {
        for line in sdp.components(separatedBy: "\r\n") {
            let prefix = "a=\(name):"
            guard line.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func testLocalUsesWMMQoSClasses() {
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "192.168.1.50", videoLocalPort: 47998, config: StreamConfig(),
            networkClass: .local, videoPacketSize: 1392
        )
        XCTAssertEqual(attribute("x-nv-vqos[0].qosTrafficType", in: sdp), "5")
        XCTAssertEqual(attribute("x-nv-aqos.qosTrafficType", in: sdp), "4")
    }

    func testRemoteUsesBestEffortQoS() {
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "100.85.29.11", videoLocalPort: 47998, config: StreamConfig(),
            networkClass: .remote, videoPacketSize: 1024
        )
        XCTAssertEqual(attribute("x-nv-vqos[0].qosTrafficType", in: sdp), "0")
        XCTAssertEqual(attribute("x-nv-aqos.qosTrafficType", in: sdp), "0")
    }

    func testRemoteTrimsBitrateBy500Kbps() {
        var config = StreamConfig()
        config.bitrate = 10_000   // adjusted = 10000 * 0.8 = 8000
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "100.85.29.11", videoLocalPort: 47998, config: config,
            networkClass: .remote, videoPacketSize: 1024
        )
        XCTAssertEqual(attribute("x-nv-video[0].initialBitrateKbps", in: sdp), "7500")
        XCTAssertEqual(attribute("x-nv-vqos[0].bw.maximumBitrateKbps", in: sdp), "7500")
        // Unadjusted configured-bitrate attribute is untouched by the remote trim.
        XCTAssertEqual(attribute("x-ml-video.configuredBitrateKbps", in: sdp), "10000")
    }

    func testLocalDoesNotTrimBitrate() {
        var config = StreamConfig()
        config.bitrate = 10_000
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "192.168.1.50", videoLocalPort: 47998, config: config,
            networkClass: .local, videoPacketSize: 1392
        )
        XCTAssertEqual(attribute("x-nv-video[0].initialBitrateKbps", in: sdp), "8000")
    }

    func testRemoteDoesNotTrimBelow500Kbps() {
        // Guards the `adjusted > 500` guard: a very low bitrate must not go negative.
        var config = StreamConfig()
        config.bitrate = 500   // adjusted = 400, already <= 500, must not be trimmed
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "100.85.29.11", videoLocalPort: 47998, config: config,
            networkClass: .remote, videoPacketSize: 1024
        )
        XCTAssertEqual(attribute("x-nv-video[0].initialBitrateKbps", in: sdp), "400")
    }

    func testPacketSizeAttributeMatchesInput() {
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "100.85.29.11", videoLocalPort: 47998, config: StreamConfig(),
            networkClass: .remote, videoPacketSize: 1024
        )
        XCTAssertEqual(attribute("x-nv-video[0].packetSize", in: sdp), "1024")
    }

    // MARK: - Phase 3: "o=" line address family and bracketing

    private func originLine(in sdp: String) -> String? {
        sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("o=") }
    }

    func testOriginLineDefaultsToIPv4() {
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "192.168.1.50", videoLocalPort: 47998, config: StreamConfig(),
            networkClass: .local, videoPacketSize: 1392
        )
        XCTAssertEqual(originLine(in: sdp), "o=android 0 14 IN IPv4 192.168.1.50")
    }

    func testOriginLineUsesIPv6AndBracketsTheAddress() {
        let sdp = SDPBuilder.buildAnnounceSDP(
            serverHost: "fd7a:115c:a1e0::1", serverFamily: AF_INET6, videoLocalPort: 47998,
            config: StreamConfig(), networkClass: .local, videoPacketSize: 1216
        )
        XCTAssertEqual(originLine(in: sdp), "o=android 0 14 IN IPv6 [fd7a:115c:a1e0::1]")
    }
}

//
//  AddressClassifierTests.swift
//  ChloroFrameTests
//
//  design/tailscale-connection-fix-plan.md Phase 2, section 6.1.
//

import XCTest
@testable import ChloroFrame

final class AddressClassifierTests: XCTestCase {

    func testIPv4LocalRanges() {
        for host in ["192.168.1.10", "10.0.0.5", "172.20.1.1", "169.254.1.1", "127.0.0.1"] {
            XCTAssertEqual(AddressClassifier.classify(numericHost: host), .local, host)
        }
    }

    func testIPv4RemoteRanges() {
        // 172.32.0.1 is just outside 172.16.0.0/12 (which ends at 172.31.255.255).
        // 100.64.0.1 / 100.127.255.254 / 100.128.0.1: Tailscale's CGNAT range (100.64.0.0/10,
        // ending at 100.127.255.255) is deliberately NOT treated as private (matches
        // moonlight's matchCGN: false), and 100.128.0.1 falls outside that range entirely
        // and isn't private either way, both end up remote for the same reason: neither is
        // in any of the five private ranges this classifier checks.
        for host in ["172.32.0.1", "100.64.0.1", "100.127.255.254", "100.128.0.1", "8.8.8.8"] {
            XCTAssertEqual(AddressClassifier.classify(numericHost: host), .remote, host)
        }
    }

    func testIPv6LocalRanges() {
        // fd7a:115c:a1e0::1 is Tailscale's own ULA range, inside fc00::/7.
        for host in ["fd7a:115c:a1e0::1", "fe80::1", "::1"] {
            XCTAssertEqual(AddressClassifier.classify(numericHost: host), .local, host)
        }
    }

    func testIPv6RemoteRanges() {
        XCTAssertEqual(AddressClassifier.classify(numericHost: "2001:4860::1"), .remote)
    }

    func testUnparseableInputDefaultsToRemote() {
        // Not an IPv4 or IPv6 literal at all (a hostname, or malformed input). The safer
        // wrong guess is smaller packets, not risking IP fragmentation.
        XCTAssertEqual(AddressClassifier.classify(numericHost: "not-an-address"), .remote)
    }
}

final class PacketSizePolicyTests: XCTestCase {

    func testLANIPv4OnWiFi() {
        XCTAssertEqual(PacketSizePolicy.choose(class: .local, family: AF_INET, interfaceMTU: 1500), 1392)
    }

    func testTailscaleIPv4() {
        XCTAssertEqual(PacketSizePolicy.choose(class: .remote, family: AF_INET, interfaceMTU: 1280), 1024)
    }

    func testTailscaleIPv6() {
        // Classified local (ULA), but still capped by the tunnel's 1280 MTU.
        XCTAssertEqual(PacketSizePolicy.choose(class: .local, family: AF_INET6, interfaceMTU: 1280), 1216)
    }

    func testPublicIPv4() {
        XCTAssertEqual(PacketSizePolicy.choose(class: .remote, family: AF_INET, interfaceMTU: 1500), 1024)
    }

    func testResolutionFailedDefaultsToLocalUncapped() {
        XCTAssertEqual(PacketSizePolicy.choose(class: .local, family: AF_INET, interfaceMTU: nil), 1392)
    }

    func testResultsAreAlwaysMultiplesOf16AndNeverExceed1392() {
        let classes: [StreamNetworkClass] = [.local, .remote]
        let families: [Int32] = [AF_INET, AF_INET6]
        let mtus: [Int?] = [nil, 576, 1024, 1200, 1280, 1400, 1500, 9000]
        for c in classes {
            for f in families {
                for mtu in mtus {
                    let size = PacketSizePolicy.choose(class: c, family: f, interfaceMTU: mtu)
                    XCTAssertEqual(size % 16, 0, "class=\(c) family=\(f) mtu=\(String(describing: mtu)) -> \(size)")
                    XCTAssertLessThanOrEqual(size, 1392)
                }
            }
        }
    }
}

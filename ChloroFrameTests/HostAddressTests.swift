//
//  HostAddressTests.swift
//  ChloroFrameTests
//
//  design/tailscale-connection-fix-plan.md Phase 3, section 6.1.
//

import XCTest
@testable import ChloroFrame

final class HostAddressTests: XCTestCase {

    // MARK: - normalized

    func testNormalizedStripsBrackets() {
        XCTAssertEqual(HostAddress.normalized("[fd7a:115c:a1e0::1]"), "fd7a:115c:a1e0::1")
    }

    func testNormalizedTrimsWhitespace() {
        XCTAssertEqual(HostAddress.normalized("  192.168.1.50  "), "192.168.1.50")
        XCTAssertEqual(HostAddress.normalized("  [fd7a::1]  "), "fd7a::1")
    }

    func testNormalizedLeavesIPv4AndHostnamesUnchanged() {
        XCTAssertEqual(HostAddress.normalized("192.168.1.50"), "192.168.1.50")
        XCTAssertEqual(HostAddress.normalized("gamehost.local"), "gamehost.local")
    }

    // MARK: - urlHost

    func testUrlHostBracketsBareIPv6() {
        XCTAssertEqual(HostAddress.urlHost("fd7a:115c:a1e0::1"), "[fd7a:115c:a1e0::1]")
    }

    func testUrlHostIsIdempotentOnAlreadyBracketedInput() {
        XCTAssertEqual(HostAddress.urlHost("[fd7a:115c:a1e0::1]"), "[fd7a:115c:a1e0::1]")
    }

    func testUrlHostLeavesIPv4AndHostnamesUnchanged() {
        XCTAssertEqual(HostAddress.urlHost("192.168.1.50"), "192.168.1.50")
        XCTAssertEqual(HostAddress.urlHost("gamehost.local"), "gamehost.local")
    }

    func testUrlHostProducesAValidURLForAllAddressForms() throws {
        for host in ["192.168.1.50", "gamehost.local", "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0::1]", "::1"] {
            var comps = URLComponents()
            comps.scheme = "http"
            comps.host = HostAddress.urlHost(host)
            comps.port = 47989
            comps.path = "/serverinfo"
            let url = try XCTUnwrap(comps.url, "urlHost(\(host)) = \(HostAddress.urlHost(host)) produced no URL")
            XCTAssertNotNil(url.host())
        }
    }
}

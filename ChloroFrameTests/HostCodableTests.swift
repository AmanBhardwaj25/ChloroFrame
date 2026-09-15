//
//  HostCodableTests.swift
//  ChloroFrameTests
//
//  Regression guard for Host's Codable backward compatibility (design/tailscale-connection-fix-
//  plan.md Phase 6, design decision 1): secondaryAddress must decode cleanly from data saved
//  before this field existed, or every user's saved host list silently disappears on next
//  launch (HostManager.load uses try?, so a decode failure just leaves hosts empty).
//
//  Type references below are qualified as ChloroFrame.Host: Foundation has its own (deprecated,
//  NSHost-bridged) `Host` class, invisible from inside the app target (Swift prefers the current
//  module's own symbol there) but genuinely ambiguous from here, where @testable import
//  ChloroFrame and the implicit Foundation import (via XCTest) present ChloroFrame.Host and
//  Foundation.Host as two equally-weighted imported candidates.
//

import XCTest
@testable import ChloroFrame

final class HostCodableTests: XCTestCase {

    func testDecodesPreSecondaryAddressJSON() throws {
        // Exactly the shape ContentView.Host produced before secondaryAddress existed: no key
        // for it at all, not even null.
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Living Room PC","address":"192.168.1.50","port":47989}]
        """
        let hosts = try JSONDecoder().decode([ChloroFrame.Host].self, from: Data(json.utf8))
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].name, "Living Room PC")
        XCTAssertEqual(hosts[0].address, "192.168.1.50")
        XCTAssertNil(hosts[0].secondaryAddress)
        XCTAssertEqual(hosts[0].port, 47989)
    }

    func testRoundTripsWithSecondaryAddress() throws {
        var host = ChloroFrame.Host(name: "Gaming PC", address: "192.168.1.200")
        host.secondaryAddress = "100.85.29.11"
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(ChloroFrame.Host.self, from: data)
        XCTAssertEqual(decoded.secondaryAddress, "100.85.29.11")
        XCTAssertEqual(decoded.address, "192.168.1.200")
    }

    func testRoundTripsWithoutSecondaryAddress() throws {
        let host = ChloroFrame.Host(name: "Gaming PC", address: "192.168.1.200")
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(ChloroFrame.Host.self, from: data)
        XCTAssertNil(decoded.secondaryAddress)
    }

    func testMemberwiseInitStillOmitsNewFields() {
        // Guards the other half of the Phase 6 design decision: the `= nil` default must keep
        // Host(name:address:) compiling without listing every property.
        let host = ChloroFrame.Host(name: "Gaming PC", address: "192.168.1.200")
        XCTAssertNil(host.secondaryAddress)
        XCTAssertEqual(host.port, 47989)
    }
}

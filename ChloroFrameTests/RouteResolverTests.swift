//
//  RouteResolverTests.swift
//  ChloroFrameTests
//
//  Portable smoke tests for RouteResolver: only loopback, which resolves the same way in any
//  test environment. Broader routing behavior (Tailscale, multi-interface) is verified by hand
//  per design/tailscale-connection-fix-plan.md §6.3, since it depends on the machine's actual
//  network state, not something a CI sandbox can assume.
//

import XCTest
@testable import ChloroFrame

final class RouteResolverTests: XCTestCase {

    func testLoopbackResolvesToLo0() {
        let route = RouteResolver.resolve(host: "127.0.0.1", port: 48010)
        let r = try! XCTUnwrap(route)
        XCTAssertEqual(r.destination, "127.0.0.1")
        XCTAssertEqual(r.interfaceName, "lo0")
        XCTAssertGreaterThan(r.interfaceIndex, 0)
    }

    func testBracketedIPv6LoopbackStripsBrackets() {
        let route = RouteResolver.resolve(host: "[::1]", port: 48010)
        let r = try! XCTUnwrap(route)
        XCTAssertEqual(r.destination, "::1")
        XCTAssertEqual(r.interfaceName, "lo0")
    }

    func testUnresolvableHostReturnsNil() {
        // A name that will not resolve under any test environment's DNS.
        XCTAssertNil(RouteResolver.resolve(host: "this.host.does.not.exist.invalid", port: 48010))
    }
}

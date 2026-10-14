//
//  PyroWaveLinkInspectorTests.swift
//  ChloroFrameTests
//
//  design/pyrowave-implementation-plan.md D5b step C6.5: what CoreWLAN reports from inside the
//  app process (no Location Services permission is requested). The environment-dependent part
//  only logs; the assertions cover interfaces whose type is the same on every Mac.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveLinkInspectorTests: XCTestCase {

    func testLoopbackAndUnknownInterfacesAreNotEthernetOrWiFi() {
        XCTAssertEqual(PyroWaveLinkInspector.inspect(interfaceName: "lo0").kind, .other)
        XCTAssertEqual(PyroWaveLinkInspector.inspect(interfaceName: "no-such-if0").kind, .other)
    }

    func testLogWhatTheRouteInterfaceReportsInsideTheApp() throws {
        guard let route = RouteResolver.resolve(host: "192.168.1.200", port: 48010) else {
            throw XCTSkip("no route to 192.168.1.200 from this machine")
        }
        let link = PyroWaveLinkInspector.inspect(interfaceName: route.interfaceName)
        DebugFileLog.write("[ChloroFrame][linkinspector-test] iface=\(route.interfaceName) kind=\(link.kind) "
                           + "band=\(link.wifiBand.map { "\($0)" } ?? "nil") linkMbps=\(link.linkMbps.map(String.init) ?? "nil")")
    }
}

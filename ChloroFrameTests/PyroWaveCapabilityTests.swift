//
//  PyroWaveCapabilityTests.swift
//  ChloroFrameTests
//

import XCTest
@testable import ChloroFrame

final class PyroWaveCapabilityTests: XCTestCase {

    func testVendoredAPIVersionIs100() {
        let v = PyroWaveVendor.apiVersion()
        XCTAssertEqual(v.major, 1)
        XCTAssertEqual(v.minor, 0)
        XCTAssertEqual(v.patch, 0)
    }

    func testGPUSupportsPyroWaveOnAppleSilicon() throws {
        #if arch(arm64)
        XCTAssertTrue(VideoCapabilities.supportsPyroWave)
        #else
        throw XCTSkip("PyroWave requires Apple silicon")
        #endif
    }

    func testBitstreamIDMatchesVibeshinePin() {
        XCTAssertEqual(PyroWaveVendor.bitstreamID, "186f0393")
    }
}

//
//  PyroWaveCapabilityTests.swift
//  ChloroFrameTests
//

import XCTest
@testable import ChloroFrame

final class PyroWaveCapabilityTests: XCTestCase {

    func testVendoredAPIVersionIs050() {
        let v = PyroWaveVendor.apiVersion()
        XCTAssertEqual(v.major, 0)
        XCTAssertEqual(v.minor, 5)
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

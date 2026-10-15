//
//  PyroWaveColorGateTests.swift
//  ChloroFrameTests
//
//  Review R1: 10-bit PyroWave frames are held until the host's HDR mode message picks the color.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveColorGateTests: XCTestCase {

    private let pq = PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: true)
    private let sdr = PlanarColorParams.forEncoderCscMode(4, bitDepth: 10, hdr: false)

    func testEightBitStreamIsNeverHeld() {
        let gate = PyroWaveColorGate(waitForHost: false)
        XCTAssertTrue(gate.allows(pq, now: 0))
        XCTAssertEqual(gate.heldFrames, 0)
    }

    func testSDRHostHoldsPQFramesUntilAFrameCarriesSDR() {
        let gate = PyroWaveColorGate(waitForHost: true)
        XCTAssertFalse(gate.allows(pq, now: 0.00), "before the message")
        XCTAssertFalse(gate.allows(pq, now: 0.02))
        gate.hostReported(sdr)
        XCTAssertFalse(gate.allows(pq, now: 0.04), "a frame already decoding keeps the PQ stamp")
        XCTAssertTrue(gate.allows(sdr, now: 0.05))
        XCTAssertEqual(gate.heldFrames, 3)
        // Open stays open: a later flip shows at once.
        XCTAssertTrue(gate.allows(pq, now: 5))
    }

    func testPQHostOpensOnTheFirstFrameAfterTheMessage() {
        let gate = PyroWaveColorGate(waitForHost: true)
        XCTAssertFalse(gate.allows(pq, now: 0))
        gate.hostReported(pq)
        XCTAssertTrue(gate.allows(pq, now: 0.016))
        XCTAssertEqual(gate.heldFrames, 1)
    }

    func testNoMessageFallsBackToTheAssumptionAfterTheTimeout() {
        let gate = PyroWaveColorGate(waitForHost: true, timeout: 0.25)
        XCTAssertFalse(gate.allows(pq, now: 10.0))
        XCTAssertFalse(gate.allows(pq, now: 10.24))
        XCTAssertTrue(gate.allows(pq, now: 10.25), "timeout counts from the first decoded frame")
        XCTAssertTrue(gate.allows(pq, now: 10.26))
    }
}

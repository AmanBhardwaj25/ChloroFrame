//
//  PyroWaveUdpProbeTests.swift
//  ChloroFrameTests
//
//  design/pyrowave-implementation-plan.md D7b: grading with synthetic arrival logs, the host's
//  XML (including the 500 form), request validation, the planned send schedule, datagram
//  filtering and the session cache rules. No network.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveUdpProbeTests: XCTestCase {

    private let packetSize = 1392
    private var expected: Int { PyroWaveUdpProbeSchedule.expectedPackets(kbps: 250_000, packetSize: packetSize) }

    /// A clean run: every packet arrives at its planned time plus a fixed offset and a small
    /// repeating jitter of under 1 ms. `drop` removes sequence numbers, `extraDelay` adds
    /// milliseconds per sequence number.
    private func arrivals(burst: (fps: Int, paceKbps: Int, ipv6: Bool)? = nil,
                          drop: (Int) -> Bool = { _ in false },
                          extraDelay: (Int) -> Double = { _ in 0 }) -> [PyroWaveUdpProbeArrival] {
        (0..<expected).compactMap { seq in
            if drop(seq) { return nil }
            let planned = PyroWaveUdpProbeSchedule.plannedMs(seq: seq, expected: expected, packetSize: packetSize, burst: burst)
            let jitter = Double((seq * 7) % 10) / 12.0
            return PyroWaveUdpProbeArrival(seq: seq, ms: 1_000_000 + planned + 0.3 + jitter + extraDelay(seq))
        }
    }

    private func grade(_ a: [PyroWaveUdpProbeArrival], sent: Int? = nil, elapsed: Double = 2000.4,
                       burst: (fps: Int, paceKbps: Int, ipv6: Bool)? = nil, duplicates: Int = 0) -> PyroWaveUdpProbeVerdict {
        PyroWaveUdpProbeGrader.grade(arrivals: a,
                                     host: (expected: expected, sent: sent ?? expected, elapsedMs: elapsed, sendRetries: 0),
                                     packetSize: packetSize, burst: burst, duplicates: duplicates)
    }

    // MARK: - Grading

    func testCleanRunPasses() {
        let v = grade(arrivals())
        XCTAssertTrue(v.passed, v.summary)
        XCTAssertEqual(v.lossPercent, 0, accuracy: 1e-9)
        XCTAssertLessThan(v.transitVariationP99Ms, 4)
        XCTAssertTrue(v.failures.isEmpty)
    }

    func testCleanBurstShapedRunPasses() {
        let burst = (fps: 60, paceKbps: 1_000_000, ipv6: false)
        let v = grade(arrivals(burst: burst), burst: burst)
        XCTAssertTrue(v.passed, v.summary)
    }

    func testHalfPercentIndependentLossFailsAggregate() {
        // Every 200th packet: 0.5 percent, spread evenly so no window is worse than 1 percent.
        let v = grade(arrivals(drop: { $0 % 200 == 100 }))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.lossPercent, 0.5, accuracy: 0.02)
        XCTAssertLessThanOrEqual(v.worstWindowLossPercent, 1.0)
        XCTAssertTrue(v.failures.contains { $0.contains("loss") })
    }

    func testLossRightAtTheLimitPasses() {
        // 0.05 percent total (every 2000th packet) is under 0.1 percent.
        let v = grade(arrivals(drop: { $0 % 2000 == 1000 }))
        XCTAssertTrue(v.passed, v.summary)
        XCTAssertLessThan(v.lossPercent, 0.1)
    }

    func testBurstLossInOneWindowFailsWindowRuleEvenWithLowAggregate() {
        // Drop 60 consecutive packets: 0.15 percent total, but about 6 percent of one window...
        // so also over the aggregate limit. Use 35 packets (0.085 percent total, 3.4 percent of
        // a window) to isolate the window rule.
        let start = expected / 2
        let v = grade(arrivals(drop: { $0 >= start && $0 < start + 35 }))
        XCTAssertLessThan(v.lossPercent, 0.1)
        XCTAssertGreaterThan(v.worstWindowLossPercent, 1.0)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains { $0.contains("100 ms window") })
    }

    func testGrowingDelayFails() {
        // The path queues up: 5 ms of extra delay by the end of the run.
        let v = grade(arrivals(extraDelay: { 5.0 * Double($0) / Double(expected) }))
        XCTAssertGreaterThan(v.delayGrowthMs, 2.0)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains { $0.contains("delay grew") })
    }

    func testJitterSpikesFailTransitVariation() {
        // 2 percent of packets arrive 12 ms late.
        let v = grade(arrivals(extraDelay: { $0 % 50 == 0 ? 12 : 0 }))
        XCTAssertGreaterThan(v.transitVariationP99Ms, 4.0)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains { $0.contains("transit variation") })
    }

    func testHostThatSentTooFewFails() {
        let v = grade(arrivals(drop: { $0 >= expected - 500 }), sent: expected - 500)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains { $0.contains("host sent only") })
    }

    func testSenderDurationOutsideTwoPercentFails() {
        XCTAssertTrue(grade(arrivals(), elapsed: 2039).passed)
        let slow = grade(arrivals(), elapsed: 2045)
        XCTAssertFalse(slow.passed)
        XCTAssertTrue(slow.failures.contains { $0.contains("send took") })
        XCTAssertFalse(grade(arrivals(), elapsed: 1950).passed)
    }

    func testNothingArrivingFailsWithBlockedUdpMessage() {
        let v = grade([])
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.received, 0)
        XCTAssertEqual(v.lossPercent, 100, accuracy: 1e-9)
        XCTAssertTrue(v.failures.contains { $0.contains("UDP blocked") })
    }

    func testSequenceNumbersBeyondExpectedAreIgnored() {
        var a = arrivals()
        a.append(PyroWaveUdpProbeArrival(seq: expected + 5, ms: 1_000_500))
        let v = grade(a)
        XCTAssertEqual(v.received, expected)
        XCTAssertTrue(v.passed)
    }

    // MARK: - Collector (duplicates and foreign tokens)

    private func datagram(token: String, seq: Int, length: Int = 1440) -> [UInt8] {
        var d = [UInt8](repeating: 0x5a, count: length)
        for (i, b) in token.utf8.enumerated() { d[i] = b }
        d[32] = UInt8((seq >> 24) & 0xff); d[33] = UInt8((seq >> 16) & 0xff)
        d[34] = UInt8((seq >> 8) & 0xff);  d[35] = UInt8(seq & 0xff)
        return d
    }

    func testCollectorCountsDuplicatesOnceAndIgnoresForeignAndWarmups() {
        let token = String(repeating: "ab", count: 16)
        let other = String(repeating: "cd", count: 16)
        var c = PyroWaveUdpProbeCollector(token: token)
        XCTAssertTrue(c.ingest(datagram(token: token, seq: 0), atMs: 1))
        XCTAssertTrue(c.ingest(datagram(token: token, seq: 1), atMs: 2))
        XCTAssertFalse(c.ingest(datagram(token: token, seq: 1), atMs: 3), "duplicate")
        XCTAssertFalse(c.ingest(datagram(token: other, seq: 2), atMs: 4), "foreign token")
        XCTAssertFalse(c.ingest(Array(token.utf8), atMs: 5), "32 byte warmup")
        XCTAssertFalse(c.ingest(datagram(token: token, seq: 9_000_000), atMs: 6), "absurd sequence")
        XCTAssertEqual(c.arrivals.map(\.seq), [0, 1])
        XCTAssertEqual(c.arrivals[1].ms, 2, "the first arrival time is kept")
        XCTAssertEqual(c.duplicates, 1)
        XCTAssertEqual(c.foreign, 2)
        XCTAssertEqual(c.tooShort, 1)
    }

    func testSequenceIsBigEndian() {
        let token = String(repeating: "0f", count: 16)
        var c = PyroWaveUdpProbeCollector(token: token)
        var d = datagram(token: token, seq: 0)
        d[32] = 0x00; d[33] = 0x01; d[34] = 0x02; d[35] = 0x03
        c.ingest(d, atMs: 0)
        XCTAssertEqual(c.arrivals.first?.seq, 0x00010203)
    }

    // MARK: - Host XML

    func testParsesHostCounts() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><expected>40958</expected><sent>40958</sent><elapsedMs>2000.31</elapsedMs>\
        <sendRetries>3</sendRetries><lastSendError>0</lastSendError></root>
        """
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data(xml.utf8)),
                       .counts(expected: 40958, sent: 40958, elapsedMs: 2000.31, sendRetries: 3, lastSendError: 0))
    }

    func testParsesFiveHundredForm() {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<root status_code=\"500\" status_message=\"The client did not complete the UDP handshake\"/>"
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data(xml.utf8)),
                       .failure(code: 500, message: "The client did not complete the UDP handshake"))
    }

    func testFiveHundredMessageIsUnescaped() {
        let xml = "<root status_code=\"500\" status_message=\"a &amp; b &lt;c&gt;\"/>"
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data(xml.utf8)), .failure(code: 500, message: "a & b <c>"))
    }

    func testMalformedBodies() {
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data()), .malformed)
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data("Stop streaming".utf8)), .malformed)
        XCTAssertEqual(PyroWaveUdpProbeHostResult.parse(Data("<root status_code=\"200\"><expected>5</expected></root>".utf8)), .malformed)
    }

    // MARK: - Request

    func testRequestValidationMatchesHostBounds() {
        func make(kbps: Int = 250_000, port: Int = 50_000, size: Int = 1392, token: String = PyroWaveUdpProbeRequest.makeToken(),
                  fps: Int? = nil, pace: Int? = nil) -> PyroWaveUdpProbeRequest {
            PyroWaveUdpProbeRequest(kbps: kbps, port: port, packetSize: size, token: token, fps: fps, paceKbps: pace)
        }
        XCTAssertNil(make().validationError)
        XCTAssertNotNil(make(kbps: 4_999).validationError)
        XCTAssertNotNil(make(kbps: 3_000_001).validationError)
        XCTAssertNotNil(make(port: 1023).validationError)
        XCTAssertNotNil(make(port: 65_536).validationError)
        XCTAssertNotNil(make(size: 255).validationError)
        XCTAssertNotNil(make(size: 1393).validationError)
        XCTAssertNotNil(make(token: "ABCDEF").validationError)
        XCTAssertNotNil(make(token: String(repeating: "A", count: 32)).validationError, "uppercase is refused")
        XCTAssertNil(make(fps: 60, pace: 250_000).validationError)
        XCTAssertNotNil(make(fps: 60).validationError, "both or neither")
        XCTAssertNotNil(make(fps: 9, pace: 300_000).validationError)
        XCTAssertNotNil(make(fps: 60, pace: 100_000).validationError, "pace below the rate")
    }

    func testTokenIsFreshLowercaseHex32() {
        let a = PyroWaveUdpProbeRequest.makeToken(), b = PyroWaveUdpProbeRequest.makeToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(a, b)
    }

    func testQueryItemsAskForHandshakeAndBurstOnlyWhenGiven() {
        let plain = PyroWaveUdpProbeRequest(kbps: 250_000, port: 50_000, packetSize: 1392,
                                            token: PyroWaveUdpProbeRequest.makeToken())
        XCTAssertEqual(plain.queryItems.map(\.name), ["kbps", "port", "packetsize", "token", "handshake"])
        XCTAssertEqual(plain.queryItems.first { $0.name == "handshake" }?.value, "1")
        var burst = plain
        burst.fps = 60; burst.paceKbps = 1_000_000
        XCTAssertEqual(burst.queryItems.suffix(2).map(\.name), ["fps", "pacekbps"])
    }

    // MARK: - Schedule

    func testExpectedPacketsMatchesHostFormula() {
        // 250000 kbps * 2000 ms / (8 * (1392 + 134)) = 40956.9, truncated
        XCTAssertEqual(PyroWaveUdpProbeSchedule.expectedPackets(kbps: 250_000, packetSize: 1392), 40_956)
    }

    func testPlannedTimesAreMonotonicAndInsideTheRun() {
        for burst in [nil, (fps: 60, paceKbps: 1_000_000, ipv6: false)] as [(fps: Int, paceKbps: Int, ipv6: Bool)?] {
            var last = -1.0
            for seq in 0..<expected {
                let t = PyroWaveUdpProbeSchedule.plannedMs(seq: seq, expected: expected, packetSize: packetSize, burst: burst)
                XCTAssertGreaterThanOrEqual(t, last)
                XCTAssertLessThan(t, 2000)
                last = t
            }
        }
    }

    func testBurstScheduleIsFrameShaped() {
        // 60 fps over 2 s is 120 frames; the first packet of frame 1 leaves at about 16.6 ms.
        let burst = (fps: 60, paceKbps: 1_000_000, ipv6: false)
        let perFrame = expected / 120
        let first = PyroWaveUdpProbeSchedule.plannedMs(seq: perFrame + 1, expected: expected, packetSize: packetSize, burst: burst)
        XCTAssertEqual(first, 16, accuracy: 1.5)
        // A whole frame leaves within a few milliseconds at 1 Gbps pacing, not across 16 ms.
        let last = PyroWaveUdpProbeSchedule.plannedMs(seq: perFrame - 2, expected: expected, packetSize: packetSize, burst: burst)
        XCTAssertLessThan(last, 5)
    }

    // MARK: - Session cache

    @MainActor
    func testAuditFactsRespectBitrateAndOutcomeKind() {
        let passing = PyroWaveUdpProbeVerdict(passed: true, expected: 10, sent: 10, received: 10, duplicates: 0,
                                              lossPercent: 0, worstWindowLossPercent: 0, transitVariationP99Ms: 0.5,
                                              delayGrowthMs: 0, senderElapsedMs: 2000, sendRetries: 0, failures: [])
        let entry = PyroWaveNetworkTest.Entry(kbps: 250_000, outcome: .graded(passing), date: Date())
        XCTAssertNil(PyroWaveNetworkTest.auditFacts(entry: nil, requestedKbps: 250_000).passed)
        XCTAssertEqual(PyroWaveNetworkTest.auditFacts(entry: entry, requestedKbps: 250_000).passed, true)
        let other = PyroWaveNetworkTest.auditFacts(entry: entry, requestedKbps: 300_000)
        XCTAssertNil(other.passed, "a result at another bitrate counts as not run")
        XCTAssertNotNil(other.summary)
        let unavailable = PyroWaveNetworkTest.Entry(kbps: 250_000, outcome: .unavailable("blocked"), date: Date())
        let facts = PyroWaveNetworkTest.auditFacts(entry: unavailable, requestedKbps: 250_000)
        XCTAssertNil(facts.passed, "could not run is never a pass or a fail")
        XCTAssertTrue(facts.summary?.contains("blocked") == true)
    }

    // MARK: - Experiment config

    func testExperimentConfigAcceptsProbeOnlyJson() throws {
        let json = #"{"udpProbeRepeats": 3, "udpProbeKbps": 250000}"#
        let cfg = try JSONDecoder().decode(PyroWaveExperimentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.udpProbeRepeats, 3)
        XCTAssertEqual(cfg.udpProbeKbps, 250_000)
        XCTAssertTrue(cfg.phases.isEmpty)
        XCTAssertEqual(PyroWaveExperimentConfig.d10Default.udpProbeRepeats, 0)
    }
}

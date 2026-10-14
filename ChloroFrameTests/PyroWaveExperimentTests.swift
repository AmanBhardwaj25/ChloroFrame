//
//  PyroWaveExperimentTests.swift
//  ChloroFrameTests
//
//  The pure pieces of the live experiment (config, loss injector, report, netstat parser) and
//  the partial delivery diagnostics the report is built from. The runner itself drives the app
//  and a real host, so it is exercised by running it, not here.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveExperimentTests: XCTestCase {

    // MARK: Loss injector

    func testIndependentLossHitsTheRequestedRate() {
        var inj = PyroWaveLossInjector(percent: 1.0, burstLength: 1)
        var dropped = 0
        for _ in 0..<1_000_000 where inj.shouldDrop() { dropped += 1 }
        XCTAssertEqual(Double(dropped) / 1_000_000 * 100, 1.0, accuracy: 0.1)
        XCTAssertEqual(inj.dropped, dropped)
        XCTAssertEqual(inj.seen, 1_000_000)
    }

    func testBurstLossKeepsTheAverageRateAndDropsRunsOfTheBurstLength() {
        var inj = PyroWaveLossInjector(percent: 0.1, burstLength: 16)
        var dropped = 0
        var runs: [Int] = []
        var current = 0
        for _ in 0..<4_000_000 {
            if inj.shouldDrop() { dropped += 1; current += 1 }
            else if current > 0 { runs.append(current); current = 0 }
        }
        XCTAssertEqual(Double(dropped) / 4_000_000 * 100, 0.1, accuracy: 0.03)
        XCTAssertGreaterThan(runs.count, 100)
        XCTAssertGreaterThanOrEqual(runs.filter { $0 >= 16 }.count * 10, runs.count * 9,
                                    "events are runs of at least the burst length")
    }

    func testZeroLossNeverDropsAndTheSequenceIsDeterministic() {
        var none = PyroWaveLossInjector(percent: 0)
        for _ in 0..<10_000 { XCTAssertFalse(none.shouldDrop()) }
        var a = PyroWaveLossInjector(percent: 5, seed: 7), b = PyroWaveLossInjector(percent: 5, seed: 7)
        for _ in 0..<1000 { XCTAssertEqual(a.shouldDrop(), b.shouldDrop()) }
    }

    // MARK: Config

    func testDefaultConfigRoundTripsAndCoversTheD10Matrix() throws {
        let cfg = PyroWaveExperimentConfig.d10Default
        let decoded = try JSONDecoder().decode(PyroWaveExperimentConfig.self,
                                               from: JSONEncoder().encode(cfg))
        XCTAssertEqual(decoded, cfg)
        XCTAssertEqual(cfg.phases.map { $0.name },
                       ["natural-off", "natural-on", "loss0.1-off", "loss0.1-on",
                        "burst0.1x16-off", "burst0.1x16-on", "loss1-off", "loss1-on"])
        XCTAssertEqual(cfg.phases.first { $0.name == "natural-on" }?.minutes, 10)
        XCTAssertTrue(cfg.phases.filter { $0.name.hasSuffix("-on") }.allSatisfy { $0.partialDelivery })
        XCTAssertTrue(cfg.phases.filter { $0.name.hasSuffix("-off") }.allSatisfy { !$0.partialDelivery })
    }

    func testMinimalJSONConfigUsesDefaults() throws {
        let json = #"{"phases":[{"name":"a","minutes":1,"partialDelivery":true}]}"#
        let cfg = try JSONDecoder().decode(PyroWaveExperimentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.phases[0].lossPercent, 0)
        XCTAssertEqual(cfg.phases[0].burstLength, 1)
        XCTAssertEqual(cfg.skipSeconds, 5)
        XCTAssertFalse(cfg.quitWhenDone)
    }

    // MARK: Netstat

    func testNetstatParserReadsTheTwoCounters() {
        let text = """
        udp:
        \t303484823 datagrams received
        \t0 with incomplete header
        \t125415 dropped due to no socket
        \t7842 dropped due to full socket buffers
        \t303228106 delivered
        """
        let s = UDPStatsParser.parse(text)
        XCTAssertEqual(s.received, 303_484_823)
        XCTAssertEqual(s.fullSocketDrops, 7842)
    }

    // MARK: Report

    private func result(lossPercent: Double = 0) -> PyroWaveExperimentReport.PhaseResult {
        var start = PyroWaveExperimentSample()
        var end = PyroWaveExperimentSample()
        start.framesLost = 10; end.framesLost = 12
        start.framesPartial = 5; end.framesPartial = 25
        start.packetsLostInPartial = 100; end.packetsLostInPartial = 300
        start.partialDecoded = 5; end.partialDecoded = 25
        start.blocksSkipped = 50; end.blocksSkipped = 450
        start.framesAssembled = 100; end.framesAssembled = 36_100
        end.injectedDrops = lossPercent > 0 ? 400 : 0
        end.packetsReceived = 100_000
        end.diagnostics.dropCritical = 1
        end.diagnostics.dropWholeBlock = 1
        end.diagnostics.releasedByDeadline = 7
        end.diagnostics.addLate(ms: 3)
        end.diagnostics.addLate(ms: 30)
        end.udpFullSocketDrops = 4
        return .init(name: "natural-on", partialDelivery: true, lossPercent: lossPercent, burstLength: 1,
                     seconds: 600, fps: [60, 60, 54], start: start, end: end, failure: nil)
    }

    func testReportShowsPartialAndLostSeparatelyWithDiagnosticsAndTheG2Term() {
        let text = PyroWaveExperimentReport.format(result())
        XCTAssertTrue(text.contains("LOST 2 (0.20/min)"), text)
        XCTAssertTrue(text.contains("PARTIAL 20 (2.00/min)"), text)
        XCTAssertTrue(text.contains("critical 1"), text)
        XCTAssertTrue(text.contains("whole block 1"), text)
        XCTAssertTrue(text.contains("by 1 ms deadline 7"), text)
        XCTAssertTrue(text.contains("late packets 2 arrived"), text)
        XCTAssertTrue(text.contains("G2 lost-frame term: PASS"), text)
        XCTAssertTrue(text.contains("+4 (system wide)") || text.contains("buffers +4"), text)
    }

    func testInjectedLossPhasesDoNotPrintAG2Verdict() {
        let text = PyroWaveExperimentReport.format(result(lossPercent: 1))
        XCTAssertFalse(text.contains("G2 lost-frame term"))
        XCTAssertTrue(text.contains("injected"), text)
    }

    func testFailedPhaseSaysWhyAndSummaryMarksItNotMeasured() {
        var r = result()
        r.failure = "no stream within 90 s"
        XCTAssertTrue(PyroWaveExperimentReport.format(r).contains("NOT MEASURED: no stream within 90 s"))
        XCTAssertTrue(PyroWaveExperimentReport.summaryTable([r]).contains("not measured"))
        XCTAssertTrue(PyroWaveExperimentReport.summaryTable([result()]).contains("natural-on"))
    }
}

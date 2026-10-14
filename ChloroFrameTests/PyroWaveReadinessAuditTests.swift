//
//  PyroWaveReadinessAuditTests.swift
//  ChloroFrameTests
//
//  design/pyrowave-implementation-plan.md D5b: every audit rule against the pure `evaluate`,
//  paired serverinfo parsing, and the notice/catalog drift guard.
//

import XCTest
@testable import ChloroFrame

final class PyroWaveReadinessAuditTests: XCTestCase {

    // MARK: - Fixtures

    /// A setup where every check passes: wired Mac, wired Vibeshine host, 290 Mbps at 1440p60.
    private func good() -> PyroWaveAuditInputs {
        var i = PyroWaveAuditInputs()
        i.gpuSupportsPyroWave = true
        i.hostCodecModeSupport = ServerInfo.scmPyroWave | 0x1
        i.hostInfo = PyroWaveHostInfo(linkMbps: 2500, wireBudgetVersion: 1, udpProbeVersion: 1,
                                      udpHandshakeVersion: 1, udpProbeBurstVersion: 1,
                                      criticalFecPercentage: 20, minParityShards: 2)
        i.networkClass = .local
        i.macLink = PyroWaveMacLink(interfaceName: "en7", kind: .ethernet, linkMbps: 2500)
        i.requestedKbps = 290_000
        i.guideKbps = 290_000
        i.packetSize = 1392
        i.maxSocketBufferBytes = 8 * 1024 * 1024
        i.suppressAWDLEnabled = true
        i.awdlHelperInstalled = true
        i.gpuDecodeMs = 0.4
        return i
    }

    private func row(_ id: String, _ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        let r = PyroWaveReadinessAudit.evaluate(i).results.first { $0.id == id }
        return r!
    }

    // MARK: - Whole report

    func testGoodSetupPassesWithNoBlockersOrWarnings() {
        let report = PyroWaveReadinessAudit.evaluate(good())
        XCTAssertFalse(report.blocked, "\(report.logLines)")
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings.map(\.id))")
        XCTAssertNil(report.fallbackHeadline)
        XCTAssertEqual(report.results.map(\.id), PyroWaveReadinessAudit.catalog.map(\.id))
    }

    func testDefaultInputsAreBlocked() {
        // Nothing known: a host we know nothing about must not get PyroWave.
        let report = PyroWaveReadinessAudit.evaluate(PyroWaveAuditInputs())
        XCTAssertTrue(report.blocked)
        XCTAssertNotNil(report.fallbackHeadline)
    }

    func testHeadlineNamesFirstFailedBlocker() {
        var i = good()
        i.networkClass = .remote
        i.macLink = PyroWaveMacLink(interfaceName: "utun4", kind: .other)
        let report = PyroWaveReadinessAudit.evaluate(i)
        XCTAssertEqual(report.firstBlocker?.id, "C4")
        XCTAssertTrue(report.fallbackHeadline!.hasPrefix("PyroWave unavailable for this host: "))
        XCTAssertTrue(report.fallbackHeadline!.hasSuffix("Streaming with HEVC."))
    }

    // MARK: - C1, C2, C3

    func testC1() {
        XCTAssertEqual(row("C1", good()).outcome, .pass)
        var i = good(); i.gpuSupportsPyroWave = false
        XCTAssertTrue(row("C1", i).failedAsBlocker)
    }

    func testC2HostPyroWaveBit() {
        var i = good(); i.hostCodecModeSupport = 0x1
        XCTAssertTrue(row("C2", i).failedAsBlocker)
        i.hostCodecModeSupport = ServerInfo.scmPyroWave
        XCTAssertEqual(row("C2", i).outcome, .pass)
        // Only the 4:4:4 bit set is not the 8-bit 4:2:0 profile we request.
        i.hostCodecModeSupport = ServerInfo.scmPyroWave444
        XCTAssertTrue(row("C2", i).failedAsBlocker)
    }

    func testC3ApolloLikeHostIsBlocked() {
        var i = good(); i.hostInfo = PyroWaveHostInfo()
        let r = row("C3", i)
        XCTAssertTrue(r.failedAsBlocker)
        if case .fail = r.outcome {} else { XCTFail("expected a hard fail, not unknown") }
    }

    /// A real Vibeshine host was seen sending only the link speed. Any PyroWave key passes.
    func testC3AnyPyroWaveKeyPasses() {
        var i = good()
        for info in [PyroWaveHostInfo(linkMbps: 1000),
                     PyroWaveHostInfo(wireBudgetVersion: 1),
                     PyroWaveHostInfo(criticalFecPercentage: 20)] {
            i.hostInfo = info
            XCTAssertEqual(row("C3", i).outcome, .pass)
        }
    }

    func testC3FetchFailureBlocksAsUnknown() {
        var i = good(); i.hostInfo = nil
        let r = row("C3", i)
        XCTAssertEqual(r.outcome, .unknown("could not read the host's paired server info"))
        XCTAssertTrue(r.failedAsBlocker)
    }

    // MARK: - C4

    func testC4() {
        XCTAssertEqual(row("C4", good()).outcome, .pass)
        var i = good(); i.networkClass = .remote
        XCTAssertTrue(row("C4", i).failedAsBlocker)
        i.networkClass = nil
        XCTAssertTrue(row("C4", i).failedAsBlocker)
    }

    // MARK: - C5

    func testC5HostLinkZeroIsBlocked() {
        var i = good()
        i.hostInfo?.linkMbps = 0
        XCTAssertTrue(row("C5", i).failedAsBlocker)
        i.hostInfo?.linkMbps = nil
        XCTAssertTrue(row("C5", i).failedAsBlocker)
        i.hostInfo?.linkMbps = 1000
        XCTAssertEqual(row("C5", i).outcome, .pass)
    }

    func testC5ZeroLinkExplainsWhatToFix() {
        var i = good(); i.hostInfo?.linkMbps = 0
        let r = row("C5", i)
        XCTAssertTrue(r.message!.contains("Wi-Fi"))
        XCTAssertTrue(r.detail!.contains("Windows"))
        XCTAssertTrue(r.detail!.contains("Linux"))
    }

    // MARK: - C6

    func testC6Ethernet() {
        XCTAssertEqual(row("C6", good()).outcome, .pass)
    }

    func testC6WiFi5And6GHzPass() {
        for band in [PyroWaveWiFiBand.ghz5, .ghz6] {
            var i = good()
            i.macLink = PyroWaveMacLink(interfaceName: "en0", kind: .wifi, wifiBand: band, linkMbps: 1200)
            XCTAssertEqual(row("C6", i).outcome, .pass, "\(band)")
            XCTAssertFalse(PyroWaveReadinessAudit.evaluate(i).blocked)
        }
    }

    func testC6WiFi24GHzIsBlocked() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "en0", kind: .wifi, wifiBand: .ghz2_4, linkMbps: 144)
        let r = row("C6", i)
        XCTAssertEqual(r.severity, .blocker)
        XCTAssertTrue(r.failedAsBlocker)
        XCTAssertTrue(PyroWaveReadinessAudit.evaluate(i).blocked)
    }

    func testC6BandUnknownIsAWarningNeverABlock() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "en0", kind: .wifi, wifiBand: nil, linkMbps: nil)
        let r = row("C6", i)
        XCTAssertEqual(r.severity, .warning)
        XCTAssertFalse(r.failedAsBlocker)
        XCTAssertTrue(r.isWarning)
        let report = PyroWaveReadinessAudit.evaluate(i)
        XCTAssertFalse(report.blocked, "\(report.logLines)")
        XCTAssertTrue(report.warnings.contains { $0.id == "C6" })
        XCTAssertEqual(r.detail, PyroWaveExperimentalNotice.bandUnknownWarning)
    }

    func testC6UtunIsBlocked() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "utun4", kind: .other)
        XCTAssertTrue(row("C6", i).failedAsBlocker)
    }

    func testC6UnresolvedRouteBlocks() {
        var i = good(); i.macLink = nil
        XCTAssertTrue(row("C6", i).failedAsBlocker)
    }

    // MARK: - C7

    func testC7HostGigabitWithFifteenHundredMbpsRequestWarns() {
        var i = good()
        i.hostInfo?.linkMbps = 1000
        i.requestedKbps = 1_500_000
        i.guideKbps = 1_500_000
        let r = row("C7", i)
        XCTAssertTrue(r.isWarning)
        XCTAssertTrue(r.message!.contains("host link 1000 Mbps"))
    }

    func testC7WiFiPhyHalvedBelowRequestWarns() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "en0", kind: .wifi, wifiBand: .ghz5, linkMbps: 866)
        i.requestedKbps = 600_000
        i.guideKbps = 600_000
        XCTAssertTrue(row("C7", i).isWarning)
        // 1200 Mbps PHY halves to 600, which exactly meets 600.
        i.macLink?.linkMbps = 1200
        XCTAssertEqual(row("C7", i).outcome, .pass)
    }

    func testC7EthernetNeedsQuarterHeadroom() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "en7", kind: .ethernet, linkMbps: 1000)
        i.requestedKbps = 810_000   // 1000 < 1.25 x 810 = 1012.5
        XCTAssertTrue(row("C7", i).isWarning)
        i.requestedKbps = 800_000   // exactly 1.25 x: passes
        XCTAssertEqual(row("C7", i).outcome, .pass)
    }

    func testC7ZeroSpeedIsUnknownAndSilent() {
        var i = good()
        i.macLink = PyroWaveMacLink(interfaceName: "en7", kind: .ethernet, linkMbps: 0)
        let r = row("C7", i)
        if case .unknown = r.outcome {} else { XCTFail("expected unknown") }
        XCTAssertFalse(r.isWarning)
        XCTAssertFalse(r.failedAsBlocker)
    }

    // MARK: - C8 to C13

    func testC8Starved() {
        var i = good()
        i.guideKbps = 290_000
        i.requestedKbps = 200_000   // 200 < 0.7 x 290 = 203
        XCTAssertTrue(row("C8", i).isWarning)
        i.requestedKbps = 203_000
        XCTAssertEqual(row("C8", i).outcome, .pass)
        i.requestedKbps = 700_000
        XCTAssertEqual(row("C8", i).outcome, .pass)
    }

    func testC9CriticalParity() {
        var i = good()
        i.hostInfo?.criticalFecPercentage = 0
        XCTAssertTrue(row("C9", i).isWarning)
        i.hostInfo?.criticalFecPercentage = nil
        XCTAssertFalse(row("C9", i).isWarning)
        i.hostInfo?.criticalFecPercentage = 20
        XCTAssertEqual(row("C9", i).outcome, .pass)
    }

    func testC10PacketSize() {
        var i = good()
        i.packetSize = 1024
        XCTAssertTrue(row("C10", i).isWarning)
        i.packetSize = 1392
        XCTAssertEqual(row("C10", i).outcome, .pass)
    }

    func testC11ThrottlingAndBattery() {
        var i = good()
        i.lowPowerModeEnabled = true
        XCTAssertTrue(row("C11", i).isWarning)
        i.lowPowerModeEnabled = false
        i.thermalState = .serious
        XCTAssertTrue(row("C11", i).isWarning)
        i.thermalState = .critical
        XCTAssertTrue(row("C11", i).isWarning)
        i.thermalState = .fair
        XCTAssertEqual(row("C11", i).outcome, .pass)
        // Battery alone is an informational note, not a warning.
        i.onBatteryPower = true
        let r = row("C11", i)
        XCTAssertEqual(r.outcome, .pass)
        XCTAssertNotNil(r.detail)
        XCTAssertFalse(PyroWaveReadinessAudit.evaluate(i).warnings.contains { $0.id == "C11" })
    }

    func testC12SocketBufferOnlyMattersAtHighBitrate() {
        var i = good()
        i.maxSocketBufferBytes = 2 * 1024 * 1024
        i.requestedKbps = 290_000
        XCTAssertEqual(row("C12", i).outcome, .pass)
        i.requestedKbps = 600_000
        i.guideKbps = 600_000
        XCTAssertTrue(row("C12", i).isWarning)
        i.maxSocketBufferBytes = 8 * 1024 * 1024
        XCTAssertEqual(row("C12", i).outcome, .pass)
    }

    func testC13AWDL() {
        var i = good()
        // Not on Wi-Fi: always passes.
        i.suppressAWDLEnabled = false
        XCTAssertEqual(row("C13", i).outcome, .pass)
        // Wi-Fi without suppression warns; with suppression but no helper warns; both ok passes.
        i.macLink = PyroWaveMacLink(interfaceName: "en0", kind: .wifi, wifiBand: .ghz5, linkMbps: 1200)
        XCTAssertTrue(row("C13", i).isWarning)
        i.suppressAWDLEnabled = true
        i.awdlHelperInstalled = false
        XCTAssertTrue(row("C13", i).isWarning)
        i.awdlHelperInstalled = true
        XCTAssertEqual(row("C13", i).outcome, .pass)
    }

    // MARK: - C14 to C17

    func testC14ReportsHostProfilesAndNeverWarns() {
        var i = good()
        i.hostCodecModeSupport = ServerInfo.scmPyroWave | ServerInfo.scmPyroWave444 | ServerInfo.scmPyroWaveHDR10
        i.userWantsHDR = true
        let r = row("C14", i)
        XCTAssertEqual(r.severity, .info)
        XCTAssertEqual(r.outcome, .pass)
        XCTAssertTrue(r.detail!.contains("4:4:4 8-bit"))
        XCTAssertTrue(r.detail!.contains("HDR10 4:2:0"))
        XCTAssertTrue(r.detail!.contains("HDR was requested"))
    }

    func testC15DecodeSpeedBands() {
        var i = good()
        i.gpuDecodeMs = 1.9
        XCTAssertEqual(row("C15", i).outcome, .pass)
        i.gpuDecodeMs = 2.5
        XCTAssertEqual(row("C15", i).severity, .warning)
        XCTAssertTrue(row("C15", i).isWarning)
        XCTAssertFalse(PyroWaveReadinessAudit.evaluate(i).blocked)
        i.gpuDecodeMs = 5.0
        XCTAssertEqual(row("C15", i).severity, .blocker)
        XCTAssertTrue(row("C15", i).failedAsBlocker)
    }

    func testC15NotMeasuredYetDoesNotBlockOrWarn() {
        var i = good(); i.gpuDecodeMs = nil
        let r = row("C15", i)
        XCTAssertFalse(r.failedAsBlocker)
        XCTAssertFalse(r.isWarning)
        XCTAssertFalse(PyroWaveReadinessAudit.evaluate(i).blocked)
    }

    func testC16NotRunIsSilentAndFailureWarns() {
        var i = good()
        XCTAssertFalse(row("C16", i).isWarning)
        i.udpTestPassed = false
        XCTAssertTrue(row("C16", i).isWarning)
        i.udpTestPassed = true
        XCTAssertEqual(row("C16", i).outcome, .pass)
    }

    func testC17IsInformational() {
        let r = row("C17", good())
        XCTAssertEqual(r.severity, .info)
        XCTAssertFalse(r.isWarning)
        XCTAssertFalse(r.failedAsBlocker)
    }

    // MARK: - Paired serverinfo parsing

    func testParsesVibeshineLikePairedServerInfo() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200">
          <hostname>GAMING-PC</hostname>
          <ServerCodecModeSupport>8454145</ServerCodecModeSupport>
          <PyroWaveHostLinkMbps>2500</PyroWaveHostLinkMbps>
          <PyroWaveBandwidthProbeBytes>33554432</PyroWaveBandwidthProbeBytes>
          <PyroWaveWireBudgetVersion>1</PyroWaveWireBudgetVersion>
          <PyroWaveUdpProbeVersion>1</PyroWaveUdpProbeVersion>
          <PyroWaveUdpHandshakeVersion>1</PyroWaveUdpHandshakeVersion>
          <PyroWaveUdpProbeBurstVersion>1</PyroWaveUdpProbeBurstVersion>
          <PyroWaveCriticalFecPercentage>20</PyroWaveCriticalFecPercentage>
          <PyroWaveMinParityShards>2</PyroWaveMinParityShards>
        </root>
        """
        let info = PyroWaveHostInfo(xml: Data(xml.utf8))
        XCTAssertEqual(info.linkMbps, 2500)
        XCTAssertEqual(info.wireBudgetVersion, 1)
        XCTAssertEqual(info.udpProbeVersion, 1)
        XCTAssertEqual(info.udpHandshakeVersion, 1)
        XCTAssertEqual(info.udpProbeBurstVersion, 1)
        XCTAssertEqual(info.criticalFecPercentage, 20)
        XCTAssertEqual(info.minParityShards, 2)
        XCTAssertTrue(info.looksLikeVibeshine)
    }

    func testParsesApolloLikeServerInfoAsAllNil() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200">
          <hostname>GAMING-PC</hostname>
          <ServerCodecModeSupport>259</ServerCodecModeSupport>
          <currentgame>0</currentgame>
        </root>
        """
        let info = PyroWaveHostInfo(xml: Data(xml.utf8))
        XCTAssertEqual(info, PyroWaveHostInfo())
        XCTAssertNil(info.linkMbps)
        XCTAssertFalse(info.looksLikeVibeshine)
    }

    func testParserToleratesGarbageAndWhitespace() {
        XCTAssertEqual(PyroWaveHostInfo(xml: Data()), PyroWaveHostInfo())
        XCTAssertEqual(PyroWaveHostInfo(xml: Data([0xFF, 0xFE, 0x00])), PyroWaveHostInfo())
        let xml = "<PyroWaveHostLinkMbps> 940 </PyroWaveHostLinkMbps><PyroWaveMinParityShards>x</PyroWaveMinParityShards>"
        let info = PyroWaveHostInfo(xml: Data(xml.utf8))
        XCTAssertEqual(info.linkMbps, 940)
        XCTAssertNil(info.minParityShards)
    }

    // MARK: - Notice and catalog stay in step

    func testNoticePromisesExactlyTheUserFacingChecks() {
        let userFacing = Set(PyroWaveReadinessAudit.catalog.filter(\.userFacing).map(\.id))
        XCTAssertEqual(PyroWaveExperimentalNotice.promisedCheckIDs, userFacing)
        let known = Set(PyroWaveReadinessAudit.catalog.map(\.id))
        XCTAssertTrue(PyroWaveExperimentalNotice.promisedCheckIDs.isSubset(of: known))
    }

    func testNoticeHasSixBulletsAndNoDashes() {
        XCTAssertEqual(PyroWaveExperimentalNotice.checklist.count, 6)
        let all = PyroWaveExperimentalNotice.fullText + PyroWaveExperimentalNotice.bandUnknownWarning
        XCTAssertFalse(all.contains("\u{2014}"), "em dash")
        XCTAssertFalse(all.contains("\u{2013}"), "en dash")
    }

    func testCatalogTitlesAreUniqueAndCoverEveryResult() {
        let ids = PyroWaveReadinessAudit.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 17)
    }
}

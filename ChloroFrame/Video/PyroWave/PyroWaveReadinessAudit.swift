//
//  PyroWaveReadinessAudit.swift
//  ChloroFrame
//
//  Per-host PyroWave readiness audit (design/pyrowave-implementation-plan.md D5b, Part B).
//  Facts are gathered elsewhere (PyroWaveAuditFacts.swift, PyroWaveLinkInspector.swift) and
//  fed in as PyroWaveAuditInputs; `evaluate` is pure so every rule is unit tested.
//
//  Check ids are stable (C1 to C17). Reuse them in logs and the HUD.
//

import Foundation

// MARK: - Host info from paired HTTPS /serverinfo

/// The PyroWave* keys of a paired HTTPS /serverinfo (vibeshine/src/nvhttp.cpp:3799-3812).
/// Every field is nil when its key is absent, which is what Apollo and Sunshine return.
nonisolated struct PyroWaveHostInfo: Equatable, Sendable {
    var linkMbps: Int?
    var wireBudgetVersion: Int?
    var udpProbeVersion: Int?
    var udpHandshakeVersion: Int?
    var udpProbeBurstVersion: Int?
    var criticalFecPercentage: Int?
    var minParityShards: Int?

    init(linkMbps: Int? = nil, wireBudgetVersion: Int? = nil, udpProbeVersion: Int? = nil,
         udpHandshakeVersion: Int? = nil, udpProbeBurstVersion: Int? = nil,
         criticalFecPercentage: Int? = nil, minParityShards: Int? = nil) {
        self.linkMbps = linkMbps
        self.wireBudgetVersion = wireBudgetVersion
        self.udpProbeVersion = udpProbeVersion
        self.udpHandshakeVersion = udpHandshakeVersion
        self.udpProbeBurstVersion = udpProbeBurstVersion
        self.criticalFecPercentage = criticalFecPercentage
        self.minParityShards = minParityShards
    }

    /// Parses a /serverinfo XML body. Pure; never throws.
    init(xml: Data) {
        let text = String(data: xml, encoding: .utf8) ?? ""
        func int(_ tag: String) -> Int? {
            guard let open = text.range(of: "<\(tag)>", options: .caseInsensitive),
                  let close = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                         range: open.upperBound..<text.endIndex) else { return nil }
            return Int(text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.init(
            linkMbps:              int("PyroWaveHostLinkMbps"),
            wireBudgetVersion:     int("PyroWaveWireBudgetVersion"),
            udpProbeVersion:       int("PyroWaveUdpProbeVersion"),
            udpHandshakeVersion:   int("PyroWaveUdpHandshakeVersion"),
            udpProbeBurstVersion:  int("PyroWaveUdpProbeBurstVersion"),
            criticalFecPercentage: int("PyroWaveCriticalFecPercentage"),
            minParityShards:       int("PyroWaveMinParityShards")
        )
    }

    /// C3: any paired `PyroWave*` key means the host is a PyroWave-capable Vibeshine build.
    /// Apollo and Sunshine send none of them. Requiring specific version keys was too strict:
    /// a real Vibeshine host was seen sending the link speed but not the wire budget or
    /// handshake versions.
    var looksLikeVibeshine: Bool {
        linkMbps != nil || wireBudgetVersion != nil || udpProbeVersion != nil
            || udpHandshakeVersion != nil || udpProbeBurstVersion != nil
            || criticalFecPercentage != nil || minParityShards != nil
    }
}

// MARK: - Mac link facts

nonisolated enum PyroWaveWiFiBand: Equatable, Sendable {
    case ghz2_4, ghz5, ghz6
}

nonisolated struct PyroWaveMacLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case ethernet, wifi, other }
    var interfaceName: String
    var kind: Kind
    /// Wi-Fi only; nil when CoreWLAN could not report it (for example no Location permission).
    var wifiBand: PyroWaveWiFiBand?
    /// Ethernet: `ifi_baudrate` in Mbps. Wi-Fi: PHY transmit rate in Mbps. nil or 0 is unknown.
    var linkMbps: Int?

    init(interfaceName: String, kind: Kind, wifiBand: PyroWaveWiFiBand? = nil, linkMbps: Int? = nil) {
        self.interfaceName = interfaceName
        self.kind = kind
        self.wifiBand = wifiBand
        self.linkMbps = linkMbps
    }
}

// MARK: - Results

nonisolated enum PyroWaveCheckSeverity: Equatable, Sendable { case blocker, warning, info }

nonisolated enum PyroWaveCheckOutcome: Equatable, Sendable {
    case pass
    case fail(String)
    case unknown(String)
}

/// What an `.unknown` outcome means for the launch decision.
nonisolated enum PyroWaveUnknownPolicy: Equatable, Sendable {
    /// A blocker that cannot be verified counts as failed (fall back to HEVC).
    case blocks
    /// Shown in the "may not work well" sheet (used for the Wi-Fi band, a user decision).
    case warns
    /// Shown only in the full report (not measured yet, or not knowable before launch).
    case silent
}

nonisolated struct PyroWaveCheckResult: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let severity: PyroWaveCheckSeverity
    let outcome: PyroWaveCheckOutcome
    var unknownPolicy: PyroWaveUnknownPolicy = .silent
    /// Extra explanation shown in the Details report (also on a pass).
    var detail: String? = nil

    /// The human text for a fail or unknown outcome, nil on pass.
    var message: String? {
        switch outcome {
        case .pass: return nil
        case .fail(let m), .unknown(let m): return m
        }
    }

    var failedAsBlocker: Bool {
        guard severity == .blocker else { return false }
        switch outcome {
        case .pass: return false
        case .fail: return true
        case .unknown: return unknownPolicy == .blocks
        }
    }

    var isWarning: Bool {
        guard severity == .warning else { return false }
        switch outcome {
        case .pass: return false
        case .fail: return true
        case .unknown: return unknownPolicy == .warns
        }
    }
}

nonisolated struct PyroWaveAuditReport: Equatable, Sendable {
    let results: [PyroWaveCheckResult]

    var blockers: [PyroWaveCheckResult] { results.filter(\.failedAsBlocker) }
    var blocked: Bool { !blockers.isEmpty }
    var warnings: [PyroWaveCheckResult] { results.filter(\.isWarning) }
    var firstBlocker: PyroWaveCheckResult? { blockers.first }

    /// One line for the launch UI, nil when nothing blocks.
    var fallbackHeadline: String? {
        guard let b = firstBlocker, let why = b.message else { return nil }
        return "PyroWave unavailable for this host: \(why). Streaming with HEVC."
    }

    /// One compact line per check, for logs.
    var logLines: [String] {
        results.map { r in
            let state: String
            switch r.outcome {
            case .pass: state = "pass"
            case .fail(let m): state = "FAIL (\(m))"
            case .unknown(let m): state = "unknown (\(m))"
            }
            return "\(r.id) \(r.title): \(state)"
        }
    }
}

// MARK: - Inputs

nonisolated struct PyroWaveAuditInputs: Sendable {
    // C1
    var gpuSupportsPyroWave = false
    // C2, C14
    var hostCodecModeSupport = 0
    // C3, C5, C7, C9. nil: the paired request failed. Present with nil fields: Apollo-like host.
    var hostInfo: PyroWaveHostInfo?
    // C4. nil: the route could not be resolved.
    var networkClass: StreamNetworkClass?
    // C6, C7, C13. nil: the route could not be resolved.
    var macLink: PyroWaveMacLink?
    // C7, C8, C12. Bitrate that will actually be requested.
    var requestedKbps = 0
    // C8. PyroWaveBitrate.defaultKbps for the same mode.
    var guideKbps = 0
    // C10. nil: unknown.
    var packetSize: Int?
    // C11
    var lowPowerModeEnabled = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var onBatteryPower: Bool?
    // C12. nil: unreadable.
    var maxSocketBufferBytes: Int?
    // C13
    var suppressAWDLEnabled = false
    var awdlHelperInstalled = false
    // C14
    var userWantsHDR = false
    var userWants444 = false
    // C15. nil when the benchmark could not run. Average GPU milliseconds per frame at the stream size.
    var gpuDecodeMs: Double?
    // C16. nil: not run, or could not run (the summary then says why).
    var udpTestPassed: Bool?
    var udpTestSummary: String?

    init() {}
}

// MARK: - Evaluation

nonisolated enum PyroWaveReadinessAudit {

    /// Static description of every check. `userFacing` rows are the ones the experimental
    /// notice promises (PyroWaveExperimentalNotice); a test keeps the two in step.
    struct Entry: Equatable, Sendable {
        let id: String
        let title: String
        let userFacing: Bool
    }

    static let catalog: [Entry] = [
        Entry(id: "C1",  title: "Apple silicon GPU",             userFacing: true),
        Entry(id: "C2",  title: "Host advertises PyroWave",      userFacing: true),
        Entry(id: "C3",  title: "Host looks like Vibeshine",     userFacing: false),
        Entry(id: "C4",  title: "Local network route",           userFacing: true),
        Entry(id: "C5",  title: "Host is wired",                 userFacing: true),
        Entry(id: "C6",  title: "This Mac's link type",          userFacing: true),
        Entry(id: "C7",  title: "Link capacity",                 userFacing: true),
        Entry(id: "C8",  title: "Bitrate is not starved",        userFacing: false),
        Entry(id: "C9",  title: "Critical packets protected",    userFacing: false),
        Entry(id: "C10", title: "Full-size packets",             userFacing: false),
        Entry(id: "C11", title: "This Mac is not throttled",     userFacing: false),
        Entry(id: "C12", title: "Receive buffer headroom",       userFacing: false),
        Entry(id: "C13", title: "AWDL suppression on Wi-Fi",     userFacing: false),
        Entry(id: "C14", title: "Host profiles",                 userFacing: false),
        Entry(id: "C15", title: "GPU decode speed",              userFacing: true),
        Entry(id: "C16", title: "UDP network test",              userFacing: false),
        Entry(id: "C17", title: "Bitstream version",             userFacing: false),
    ]

    // Thresholds from the plan's table.
    static let hostLinkHeadroom = 1.25
    static let wifiPhyEfficiency = 0.5
    static let starvedFraction = 0.7
    static let fullPacketSize = 1392
    static let socketBufferBytes = 8 * 1024 * 1024
    static let socketBufferMattersAboveMbps = 400.0
    static let decodeBlockerMs = 4.0
    static let decodeWarningMs = 2.0

    static func evaluate(_ i: PyroWaveAuditInputs) -> PyroWaveAuditReport {
        PyroWaveAuditReport(results: [
            c1(i), c2(i), c3(i), c4(i), c5(i), c6(i), c7(i), c8(i), c9(i),
            c10(i), c11(i), c12(i), c13(i), c14(i), c15(i), c16(i), c17(i),
        ])
    }

    // MARK: Rows

    private static func title(_ id: String) -> String {
        catalog.first { $0.id == id }?.title ?? id
    }

    private static func make(_ id: String, _ severity: PyroWaveCheckSeverity, _ outcome: PyroWaveCheckOutcome,
                             unknown: PyroWaveUnknownPolicy = .silent, detail: String? = nil) -> PyroWaveCheckResult {
        PyroWaveCheckResult(id: id, title: title(id), severity: severity, outcome: outcome,
                            unknownPolicy: unknown, detail: detail)
    }

    private static func mbps(_ kbps: Int) -> String { "\(Int((Double(kbps) / 1000).rounded())) Mbps" }

    private static func c1(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        i.gpuSupportsPyroWave
            ? make("C1", .blocker, .pass)
            : make("C1", .blocker, .fail("this Mac's GPU cannot run the PyroWave decoder (Apple silicon is required)"))
    }

    private static func c2(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        (i.hostCodecModeSupport & ServerInfo.scmPyroWave) != 0
            ? make("C2", .blocker, .pass)
            : make("C2", .blocker, .fail("the host does not advertise PyroWave (it must run Vibeshine with PyroWave enabled)"))
    }

    /// Informational only (user decision): C2 already requires the host to advertise PyroWave,
    /// and a missing fingerprint must never push a real Vibeshine host back to HEVC.
    private static func c3(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let info = i.hostInfo else {
            return make("C3", .info, .unknown("could not read the host's paired server info"))
        }
        return info.looksLikeVibeshine
            ? make("C3", .info, .pass)
            : make("C3", .info, .unknown("the host sent no PyroWave details in its paired server info"),
                   detail: "Informational. Not a Vibeshine build that reports them, or not Vibeshine at all.")
    }

    private static func c4(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        switch i.networkClass {
        case .some(.local):
            return make("C4", .blocker, .pass)
        case .some(.remote):
            return make("C4", .blocker, .fail(
                "the route to this host is not a local network (VPN, Tailscale or internet path)"),
                detail: "Hosts saved by a Tailscale address or a public address are treated as remote.")
        case .none:
            return make("C4", .blocker, .unknown("could not determine the network route to this host"), unknown: .blocks)
        }
    }

    private static func c5(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let info = i.hostInfo else {
            return make("C5", .blocker, .unknown("could not read the host's paired server info"), unknown: .blocks)
        }
        guard let link = info.linkMbps else {
            return make("C5", .blocker, .fail("the host did not report a wired link speed"))
        }
        if link > 0 {
            return make("C5", .blocker, .pass, detail: "Host link speed \(link) Mbps.")
        }
        return make("C5", .blocker, .fail(
            "the host reports no wired link to this Mac (its route is Wi-Fi, a tunnel or virtual adapter, or its link could not be identified)"),
            detail: "Windows hosts count only Ethernet adapters; Linux hosts skip wireless, virtual, half-duplex and inactive links; other platforms report 0.")
    }

    private static func c6(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let link = i.macLink else {
            return make("C6", .blocker, .unknown("could not identify this Mac's network interface for the route"), unknown: .blocks)
        }
        switch link.kind {
        case .ethernet:
            return make("C6", .blocker, .pass, detail: "Ethernet on \(link.interfaceName).")
        case .wifi:
            switch link.wifiBand {
            case .some(.ghz5), .some(.ghz6):
                return make("C6", .blocker, .pass,
                            detail: "Wi-Fi on \(link.interfaceName), \(link.wifiBand == .ghz6 ? "6" : "5") GHz.")
            case .some(.ghz2_4):
                return make("C6", .blocker, .fail("this Mac is on 2.4 GHz Wi-Fi, which cannot carry PyroWave"))
            case .none:
                return make("C6", .warning,
                            .unknown("band unknown: couldn't verify that this Mac is on 5 GHz or 6 GHz Wi-Fi"),
                            unknown: .warns, detail: PyroWaveExperimentalNotice.bandUnknownWarning)
            }
        case .other:
            return make("C6", .blocker, .fail(
                "this Mac reaches the host over \(link.interfaceName), which is not Ethernet or Wi-Fi (VPN, bridge or unknown interface)"))
        }
    }

    private static func c7(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard i.requestedKbps > 0 else { return make("C7", .warning, .unknown("no bitrate requested")) }
        let want = Double(i.requestedKbps) / 1000
        var fails: [String] = []
        var unknowns: [String] = []

        // Host link.
        if let host = i.hostInfo?.linkMbps, host > 0 {
            if Double(host) < want * hostLinkHeadroom {
                fails.append("host link \(host) Mbps is under 1.25 times the requested \(Int(want.rounded())) Mbps")
            }
        } else {
            unknowns.append("host link speed")
        }

        // This Mac's link.
        if let link = i.macLink, let rate = link.linkMbps, rate > 0 {
            switch link.kind {
            case .ethernet:
                if Double(rate) < want * hostLinkHeadroom {
                    fails.append("this Mac's Ethernet link \(rate) Mbps is under 1.25 times the requested \(Int(want.rounded())) Mbps")
                }
            case .wifi:
                if Double(rate) * wifiPhyEfficiency < want {
                    fails.append("this Mac's Wi-Fi rate \(rate) Mbps (about \(Int((Double(rate) * wifiPhyEfficiency).rounded())) Mbps in practice) is under the requested \(Int(want.rounded())) Mbps")
                }
            case .other:
                unknowns.append("this Mac's link speed")
            }
        } else {
            unknowns.append("this Mac's link speed")
        }

        if !fails.isEmpty {
            return make("C7", .warning, .fail(fails.joined(separator: "; ")))
        }
        if !unknowns.isEmpty {
            return make("C7", .warning, .unknown("could not read: \(unknowns.joined(separator: ", "))"))
        }
        return make("C7", .warning, .pass)
    }

    private static func c8(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard i.requestedKbps > 0, i.guideKbps > 0 else { return make("C8", .warning, .unknown("no bitrate to compare")) }
        if Double(i.requestedKbps) >= Double(i.guideKbps) * starvedFraction {
            return make("C8", .warning, .pass, detail: "Requested \(mbps(i.requestedKbps)), guide \(mbps(i.guideKbps)).")
        }
        return make("C8", .warning, .fail(
            "requested \(mbps(i.requestedKbps)) is under 70 percent of the recommended \(mbps(i.guideKbps)), so quality will fall apart"))
    }

    private static func c9(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let pct = i.hostInfo?.criticalFecPercentage else {
            return make("C9", .warning, .unknown("host did not report its critical packet parity"))
        }
        return pct > 0
            ? make("C9", .warning, .pass, detail: "Critical parity \(pct) percent.")
            : make("C9", .warning, .fail("the host sends no parity for the critical packets, so one lost packet drops the whole frame"))
    }

    private static func c10(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let size = i.packetSize else { return make("C10", .warning, .unknown("packet size unknown")) }
        return size == fullPacketSize
            ? make("C10", .warning, .pass)
            : make("C10", .warning, .fail("packets would be \(size) bytes instead of \(fullPacketSize) (a tunnel or small MTU), which multiplies the packet rate"))
    }

    private static func c11(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        var issues: [String] = []
        if i.lowPowerModeEnabled { issues.append("Low Power Mode is on") }
        if i.thermalState == .serious || i.thermalState == .critical { issues.append("this Mac is thermally throttled") }
        if !issues.isEmpty {
            return make("C11", .warning, .fail(issues.joined(separator: " and ")))
        }
        return make("C11", .warning, .pass,
                    detail: i.onBatteryPower == true
                        ? "On battery power: this Mac may run hotter and throttle sooner."
                        : nil)
    }

    private static func c12(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let bytes = i.maxSocketBufferBytes else {
            return make("C12", .warning, .unknown("could not read kern.ipc.maxsockbuf"))
        }
        if Double(i.requestedKbps) / 1000 < socketBufferMattersAboveMbps {
            return make("C12", .warning, .pass, detail: "Only matters above about 400 Mbps.")
        }
        return bytes >= socketBufferBytes
            ? make("C12", .warning, .pass)
            : make("C12", .warning, .fail("the system socket buffer limit is \(bytes / 1024) KiB, under the 8 MiB needed for this bitrate"))
    }

    private static func c13(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let link = i.macLink else { return make("C13", .warning, .unknown("interface unknown")) }
        guard link.kind == .wifi else { return make("C13", .warning, .pass, detail: "Not on Wi-Fi.") }
        if i.suppressAWDLEnabled && i.awdlHelperInstalled { return make("C13", .warning, .pass) }
        if !i.suppressAWDLEnabled {
            return make("C13", .warning, .fail("AWDL suppression is off, so AirDrop and Handoff can steal Wi-Fi airtime during the stream"))
        }
        return make("C13", .warning, .fail("AWDL suppression is on but its helper is not installed (see Settings, Network)"))
    }

    private static func c14(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        let m = i.hostCodecModeSupport
        var hostProfiles: [String] = []
        if m & ServerInfo.scmPyroWave != 0          { hostProfiles.append("4:2:0 8-bit") }
        if m & ServerInfo.scmPyroWave444 != 0       { hostProfiles.append("4:4:4 8-bit") }
        if m & ServerInfo.scmPyroWaveHDR10 != 0     { hostProfiles.append("HDR10 4:2:0") }
        if m & ServerInfo.scmPyroWaveHDR10_444 != 0 { hostProfiles.append("HDR10 4:4:4") }
        let host = hostProfiles.isEmpty ? "none" : hostProfiles.joined(separator: ", ")
        // Until D8 and D9 land, ChloroFrame always requests 8-bit 4:2:0.
        var note = "Host offers: \(host). Will use: 4:2:0 8-bit."
        if i.userWantsHDR  { note += " HDR was requested but PyroWave HDR10 is not supported yet." }
        if i.userWants444  { note += " 4:4:4 was requested but is not supported yet." }
        return make("C14", .info, .pass, detail: note)
    }

    private static func c15(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let ms = i.gpuDecodeMs else {
            return make("C15", .blocker, .unknown("decode benchmark did not run"),
                        unknown: .silent, detail: "The GPU decode benchmark at the stream size could not be completed.")
        }
        let text = String(format: "%.2f ms", ms)
        if ms < decodeWarningMs { return make("C15", .blocker, .pass, detail: "Average GPU decode \(text).") }
        if ms <= decodeBlockerMs {
            return make("C15", .warning, .fail("average GPU decode takes \(text), over the 2 ms target"))
        }
        return make("C15", .blocker, .fail("average GPU decode takes \(text), over the 4 ms limit"))
    }

    private static func c16(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        guard let passed = i.udpTestPassed else {
            // Not run (or could not run): a warning, so the user hears that the path is unmeasured
            // without the launch being delayed to measure it.
            return make("C16", .warning, .unknown(i.udpTestSummary ?? "network test not run"), unknown: .warns,
                        detail: "Use Test network in the app list to measure loss and jitter on this path before streaming.")
        }
        return passed
            ? make("C16", .warning, .pass, detail: i.udpTestSummary)
            : make("C16", .warning, .fail(i.udpTestSummary ?? "the UDP test showed loss or jitter above Vibeshine's thresholds"))
    }

    private static func c17(_ i: PyroWaveAuditInputs) -> PyroWaveCheckResult {
        make("C17", .info, .unknown("only known when the stream starts"), unknown: .silent,
             detail: "The host's bitstream id is compared with \(PyroWaveVendor.bitstreamID) at stream start and shown in the HUD.")
    }
}

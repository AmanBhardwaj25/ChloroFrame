//
//  PyroWaveExperiment.swift
//  ChloroFrame
//
//  Pure logic behind the DEBUG-only live experiment runner (PyroWaveExperimentRunner.swift):
//  the experiment config, the software loss injector and the report formatter. Nothing here
//  logs or touches the network, and nothing in this file is reachable from a Release build's
//  receive path (the hooks that use it are `#if DEBUG`).
//

import Foundation

// MARK: - Config

/// What a run does. Loaded from `/tmp/chloroframe-experiment.json` at launch (DEBUG), or the
/// default D10 set from the Stream menu.
nonisolated struct PyroWaveExperimentConfig: Codable, Equatable {
    struct Phase: Codable, Equatable {
        var name: String
        var minutes: Double
        /// `pyroWavePartialDelivery` for this phase (false is the whole-frame baseline).
        var partialDelivery: Bool
        /// Software loss applied to received video datagrams, percent of packets. 0 = none.
        var lossPercent: Double = 0
        /// Mean consecutive packets per loss event. 1 = independent drops; 16 or more imitates a
        /// Wi-Fi aggregate being lost.
        var burstLength: Int = 1

        init(name: String, minutes: Double, partialDelivery: Bool, lossPercent: Double = 0, burstLength: Int = 1) {
            self.name = name
            self.minutes = minutes
            self.partialDelivery = partialDelivery
            self.lossPercent = lossPercent
            self.burstLength = burstLength
        }

        // Synthesized Decodable ignores property defaults, so a hand written config would need
        // every key. Missing optional keys take their defaults instead.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            minutes = try c.decode(Double.self, forKey: .minutes)
            partialDelivery = try c.decode(Bool.self, forKey: .partialDelivery)
            lossPercent = try c.decodeIfPresent(Double.self, forKey: .lossPercent) ?? 0
            burstLength = try c.decodeIfPresent(Int.self, forKey: .burstLength) ?? 1
        }
    }

    /// Saved host to use (name or address). nil: the only saved host, else the first.
    var hostName: String?
    /// App to launch. nil: the first app in the list.
    var appTitle: String?
    /// Seconds to wait for the stream to start and decode its first frame.
    var startupTimeoutSeconds: Double = 90
    /// Seconds of the window ignored after the first decoded frame (startup transients).
    var skipSeconds: Double = 5
    var quitWhenDone: Bool = false
    /// Runs the UDP network test (D7b) this many times before the first phase and puts each
    /// result in the report. 0 = not at all. With no phases this makes a probe-only run.
    var udpProbeRepeats: Int = 0
    /// Bitrate for those probes in kbps. nil: the same bitrate a PyroWave launch would request.
    var udpProbeKbps: Int?
    /// Ask the host even when its paired server info does not advertise the probe.
    var udpProbeIgnoreVersionKeys: Bool = false
    /// false: the even 1 ms schedule instead of frame-shaped bursts (to separate the two).
    var udpProbeFrameShaped: Bool = true
    /// Overrides the "4:4:4 chroma (PyroWave)" setting for the run (D8); the stored value comes
    /// back afterwards. nil: leave the setting alone.
    var chroma444: Bool?
    /// Overrides the HDR setting for the run (D9): true asks for HDR10 PyroWave (10-bit, PQ when
    /// the host display is HDR). The stored value comes back afterwards. nil: leave it alone.
    var hdr: Bool?
    var phases: [Phase]

    init(hostName: String? = nil, appTitle: String? = nil, startupTimeoutSeconds: Double = 90,
         skipSeconds: Double = 5, quitWhenDone: Bool = false, udpProbeRepeats: Int = 0,
         udpProbeKbps: Int? = nil, phases: [Phase]) {
        self.udpProbeRepeats = udpProbeRepeats
        self.udpProbeKbps = udpProbeKbps
        self.hostName = hostName
        self.appTitle = appTitle
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.skipSeconds = skipSeconds
        self.quitWhenDone = quitWhenDone
        self.phases = phases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        appTitle = try c.decodeIfPresent(String.self, forKey: .appTitle)
        startupTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .startupTimeoutSeconds) ?? 90
        skipSeconds = try c.decodeIfPresent(Double.self, forKey: .skipSeconds) ?? 5
        quitWhenDone = try c.decodeIfPresent(Bool.self, forKey: .quitWhenDone) ?? false
        udpProbeRepeats = try c.decodeIfPresent(Int.self, forKey: .udpProbeRepeats) ?? 0
        udpProbeKbps = try c.decodeIfPresent(Int.self, forKey: .udpProbeKbps)
        udpProbeIgnoreVersionKeys = try c.decodeIfPresent(Bool.self, forKey: .udpProbeIgnoreVersionKeys) ?? false
        udpProbeFrameShaped = try c.decodeIfPresent(Bool.self, forKey: .udpProbeFrameShaped) ?? true
        chroma444 = try c.decodeIfPresent(Bool.self, forKey: .chroma444)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr)
        phases = try c.decodeIfPresent([Phase].self, forKey: .phases) ?? []
    }

    /// The D10 A/B: natural network on and off, then software loss, independent and bursty.
    static var d10Default: PyroWaveExperimentConfig {
        func pair(_ tag: String, minutes: Double, loss: Double, burst: Int = 1) -> [Phase] {
            [Phase(name: "\(tag)-off", minutes: minutes, partialDelivery: false, lossPercent: loss, burstLength: burst),
             Phase(name: "\(tag)-on", minutes: minutes, partialDelivery: true, lossPercent: loss, burstLength: burst)]
        }
        return PyroWaveExperimentConfig(
            phases: pair("natural", minutes: 10, loss: 0)
                  + pair("loss0.1", minutes: 3, loss: 0.1)
                  + pair("burst0.1x16", minutes: 3, loss: 0.1, burst: 16)
                  + pair("loss1", minutes: 3, loss: 1))
    }
}

// MARK: - Loss injection

/// Drops packets with an average probability of `percent`, in bursts of `burstLength`.
/// Not thread safe: owned by the receive thread. Deterministic for a given seed.
nonisolated struct PyroWaveLossInjector {
    private var state: UInt64
    private let eventProbability: Double
    private let burstLength: Int
    private var burstRemaining = 0
    private(set) var dropped = 0
    private(set) var seen = 0

    init(percent: Double, burstLength: Int = 1, seed: UInt64 = 0x5EED_D10) {
        self.state = seed
        self.burstLength = max(1, burstLength)
        // A burst of L packets starts with probability p / L, so the long run drop rate is p.
        self.eventProbability = max(0, min(1, percent / 100.0)) / Double(max(1, burstLength))
    }

    private mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// True when this packet should be discarded before it reaches the queue.
    mutating func shouldDrop() -> Bool {
        seen += 1
        if burstRemaining > 0 {
            burstRemaining -= 1
            dropped += 1
            return true
        }
        if eventProbability > 0 && nextUnit() < eventProbability {
            burstRemaining = burstLength - 1
            dropped += 1
            return true
        }
        return false
    }
}

// MARK: - Window summary

/// Cumulative counters at one instant. The report is the difference of two of these.
nonisolated struct PyroWaveExperimentSample: Equatable {
    var framesAssembled = 0
    var framesLost = 0
    var framesPartial = 0
    var packetsLostInPartial = 0
    var packetsReceived = 0
    var framesDropped = 0
    var diagnostics = PartialDiagnostics()
    // Decoder
    var decoded = 0
    var partialDecoded = 0
    var blocksSkipped = 0
    var mailboxReplaced = 0
    var parseRejects = 0
    var pushRejects = 0
    var incomplete = 0
    var gpuMsAvg = 0.0
    var gpuMsMax = 0.0
    // Injection and kernel
    var injectedDrops = 0
    var udpFullSocketDrops = 0
    var udpDatagramsReceived = 0
}

/// Why partial delivery fell back to dropping a frame, how a partial frame was released, and
/// how late the packets were that arrived after it was released (D10 diagnostics).
nonisolated struct PartialDiagnostics: Equatable {
    var dropFirstPacket = 0       // frame header / sequence header packet missing
    var dropWholeBlock = 0        // a whole FEC block never arrived
    var dropCritical = 0          // a packet of the critical prefix was missing after FEC
    var dropIneligible = 0        // no critical count, no record-start flag, extended header
    var releasedByDeadline = 0    // 1 ms silence deadline
    var releasedAtBoundary = 0    // next block or next frame started
    var lateCount = 0             // unique packets for a frame already delivered partially
    var lateSumMs = 0.0
    var lateMaxMs = 0.0
    var lateUnder1 = 0, lateUnder2 = 0, lateUnder5 = 0, lateUnder20 = 0, lateOver20 = 0

    // DEBUG builds only (the queue does not call these in Release).
    // Packets that arrived after their frame had been DROPPED, and how late.
    var lateDroppedCount = 0
    var lateDroppedSumMs = 0.0
    var lateDroppedMaxMs = 0.0
    var lateDroppedUnder5 = 0, lateDroppedUnder20 = 0, lateDroppedUnder100 = 0, lateDroppedOver100 = 0
    // Largest silence between two packets of the same frame, for each frame that was dropped or
    // delivered partially: how long the stall inside the frame was.
    var gapFrames = 0
    var gapMaxMs = 0.0
    var gapUnder2 = 0, gapUnder5 = 0, gapUnder10 = 0, gapUnder20 = 0, gapUnder50 = 0, gapOver50 = 0

    var totalDrops: Int { dropFirstPacket + dropWholeBlock + dropCritical + dropIneligible }

    mutating func addLateDropped(ms: Double) {
        lateDroppedCount += 1
        lateDroppedSumMs += ms
        lateDroppedMaxMs = max(lateDroppedMaxMs, ms)
        switch ms {
        case ..<5: lateDroppedUnder5 += 1
        case ..<20: lateDroppedUnder20 += 1
        case ..<100: lateDroppedUnder100 += 1
        default: lateDroppedOver100 += 1
        }
    }

    mutating func addFrameGap(ms: Double) {
        gapFrames += 1
        gapMaxMs = max(gapMaxMs, ms)
        switch ms {
        case ..<2: gapUnder2 += 1
        case ..<5: gapUnder5 += 1
        case ..<10: gapUnder10 += 1
        case ..<20: gapUnder20 += 1
        case ..<50: gapUnder50 += 1
        default: gapOver50 += 1
        }
    }

    mutating func addLate(ms: Double) {
        lateCount += 1
        lateSumMs += ms
        lateMaxMs = max(lateMaxMs, ms)
        switch ms {
        case ..<1: lateUnder1 += 1
        case ..<2: lateUnder2 += 1
        case ..<5: lateUnder5 += 1
        case ..<20: lateUnder20 += 1
        default: lateOver20 += 1
        }
    }
}

nonisolated enum PyroWaveExperimentReport {

    struct PhaseResult {
        var name: String
        var partialDelivery: Bool
        var lossPercent: Double
        var burstLength: Int
        var seconds: Double
        var fps: [Double]            // one sample per second
        var start: PyroWaveExperimentSample
        var end: PyroWaveExperimentSample
        var failure: String?         // the phase did not produce a measurement
        var profile: String?         // "4:2:0 10-bit, picture HDR (PQ)" (D9)
    }

    private static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }

    static func format(_ r: PhaseResult) -> String {
        var out = "===== \(r.name): partial delivery \(r.partialDelivery ? "ON" : "OFF")"
        if r.lossPercent > 0 { out += ", injected loss \(r.lossPercent)% in bursts of \(r.burstLength)" }
        out += " =====\n"
        if let profile = r.profile { out += "profile      \(profile)\n" }
        if let failure = r.failure {
            return out + "NOT MEASURED: \(failure)\n"
        }
        let mins = max(r.seconds, 1) / 60
        let a = r.start, b = r.end
        let d = b.diagnostics, d0 = a.diagnostics
        let lost = b.framesLost - a.framesLost
        let partial = b.framesPartial - a.framesPartial
        let partialDecoded = b.partialDecoded - a.partialDecoded
        let skipped = b.blocksSkipped - a.blocksSkipped
        let assembled = b.framesAssembled - a.framesAssembled
        let pkts = b.packetsReceived - a.packetsReceived
        let low = r.fps.filter { $0 < 55 }.count

        out += String(format: "window %.0f s (%.1f min)\n", r.seconds, mins)
        out += String(format: "fps          median %.0f, seconds under 55: %d of %d\n",
                      median(r.fps), low, r.fps.count)
        out += String(format: "frames       assembled %d   LOST %d (%.2f/min)   PARTIAL %d (%.2f/min)\n",
                      assembled, lost, Double(lost) / mins, partial, Double(partial) / mins)
        if partialDecoded > 0 {
            out += String(format: "partial      %.1f packets lost and %.1f blocks skipped per partial frame\n",
                          Double(b.packetsLostInPartial - a.packetsLostInPartial) / Double(max(partial, 1)),
                          Double(skipped) / Double(partialDecoded))
        }
        out += "drops        first packet \(d.dropFirstPacket - d0.dropFirstPacket), "
            + "whole block \(d.dropWholeBlock - d0.dropWholeBlock), "
            + "critical \(d.dropCritical - d0.dropCritical), "
            + "ineligible \(d.dropIneligible - d0.dropIneligible)\n"
        out += "released     by 1 ms deadline \(d.releasedByDeadline - d0.releasedByDeadline), "
            + "at a block or frame boundary \(d.releasedAtBoundary - d0.releasedAtBoundary)\n"
        let late = d.lateCount - d0.lateCount
        if late > 0 {
            out += String(format: "late packets %d arrived after their frame was delivered: mean %.1f ms, max %.1f ms; "
                          + "<1 ms %d, <2 %d, <5 %d, <20 %d, >=20 %d\n",
                          late, (d.lateSumMs - d0.lateSumMs) / Double(late), d.lateMaxMs,
                          d.lateUnder1 - d0.lateUnder1, d.lateUnder2 - d0.lateUnder2,
                          d.lateUnder5 - d0.lateUnder5, d.lateUnder20 - d0.lateUnder20,
                          d.lateOver20 - d0.lateOver20)
        } else {
            out += "late packets 0 after a partial delivery\n"
        }
        let lateDropped = d.lateDroppedCount - d0.lateDroppedCount
        if lateDropped > 0 {
            out += String(format: "late dropped %d packets arrived after their frame was DROPPED: mean %.1f ms, max %.1f ms; "
                          + "<5 ms %d, <20 %d, <100 %d, >=100 %d\n",
                          lateDropped, (d.lateDroppedSumMs - d0.lateDroppedSumMs) / Double(lateDropped),
                          d.lateDroppedMaxMs,
                          d.lateDroppedUnder5 - d0.lateDroppedUnder5, d.lateDroppedUnder20 - d0.lateDroppedUnder20,
                          d.lateDroppedUnder100 - d0.lateDroppedUnder100, d.lateDroppedOver100 - d0.lateDroppedOver100)
        } else if d.lateDroppedCount > 0 || d.gapFrames > 0 {
            out += "late dropped 0 packets arrived after their frame was dropped\n"
        }
        let gaps = d.gapFrames - d0.gapFrames
        if gaps > 0 {
            out += String(format: "stall        largest gap inside %d affected frames (max %.1f ms): "
                          + "<2 ms %d, <5 %d, <10 %d, <20 %d, <50 %d, >=50 %d\n",
                          gaps, d.gapMaxMs,
                          d.gapUnder2 - d0.gapUnder2, d.gapUnder5 - d0.gapUnder5, d.gapUnder10 - d0.gapUnder10,
                          d.gapUnder20 - d0.gapUnder20, d.gapUnder50 - d0.gapUnder50, d.gapOver50 - d0.gapOver50)
        }
        let injected = b.injectedDrops - a.injectedDrops
        if r.lossPercent > 0 {
            let total = pkts + injected
            out += String(format: "injected     %d packets dropped of %d (%.3f%%)\n",
                          injected, total, total > 0 ? 100 * Double(injected) / Double(total) : 0)
        }
        out += String(format: "decode       GPU avg %.2f ms max %.2f ms, parse rejects %d, push rejects %d, "
                      + "incomplete %d, mailbox replaced %d\n",
                      b.gpuMsAvg, b.gpuMsMax, b.parseRejects - a.parseRejects, b.pushRejects - a.pushRejects,
                      b.incomplete - a.incomplete, b.mailboxReplaced - a.mailboxReplaced)
        out += "kernel       UDP datagrams received +\(b.udpDatagramsReceived - a.udpDatagramsReceived), "
            + "dropped due to full socket buffers +\(b.udpFullSocketDrops - a.udpFullSocketDrops) (system wide)\n"
        if r.lossPercent == 0 {
            let ok = Double(lost) / mins < 1
            out += String(format: "G2 lost-frame term: %@ (%.2f/min, bar under 1/min; %@)\n",
                          ok ? "PASS" : "FAIL", Double(lost) / mins,
                          mins >= 10 ? "window is 10 min or longer" : "window shorter than the 10 min G2 needs")
        }
        return out
    }

    /// One line per phase, for the end of the file.
    static func summaryTable(_ results: [PhaseResult]) -> String {
        var out = "SUMMARY (per minute)\nphase                      lost   partial   drops(first/block/critical)  late pkts\n"
        for r in results {
            guard r.failure == nil else {
                out += String(format: "%-26@ not measured\n", r.name as NSString)
                continue
            }
            let mins = max(r.seconds, 1) / 60
            let d = r.end.diagnostics, d0 = r.start.diagnostics
            out += String(format: "%-26@ %6.2f  %8.2f   %d/%d/%d  %d\n",
                          r.name as NSString,
                          Double(r.end.framesLost - r.start.framesLost) / mins,
                          Double(r.end.framesPartial - r.start.framesPartial) / mins,
                          d.dropFirstPacket - d0.dropFirstPacket, d.dropWholeBlock - d0.dropWholeBlock,
                          d.dropCritical - d0.dropCritical, d.lateCount - d0.lateCount)
        }
        return out
    }
}

/// Parses `netstat -s -p udp` output for the two counters the report uses.
nonisolated enum UDPStatsParser {
    static func parse(_ text: String) -> (received: Int, fullSocketDrops: Int) {
        var received = 0, full = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let n = Int(trimmed[..<space]) else { continue }
            if trimmed.contains("datagrams received") { received = n }
            if trimmed.contains("dropped due to full socket buffers") { full = n }
        }
        return (received, full)
    }
}

//
//  CodecRegression.swift
//  ChloroFrame
//
//  Pure logic behind the DEBUG-only codec regression run: every codec with HDR off and
//  on, a few minutes each, through the normal launch flow (the runner is
//  PyroWaveExperimentRunner, which drives phases that carry a `codec`). This file holds the
//  per-second sample, the verdict rules and the report text; it logs nothing and touches no
//  network, so like PyroWaveExperiment.swift it compiles in every build but only the DEBUG runner
//  uses it.
//

import Foundation

/// One 1 Hz reading of the stream, taken from `StreamStatsCollector.current`.
nonisolated struct CodecSecondSample: Equatable {
    var fps = 0.0
    var bitrateMbps = 0.0
    var jitterMs = 0.0
    var decodeAvgMs = 0.0
    var decodeMaxMs = 0.0
    var drawP99Ms = 0.0
    var drawMaxMs = 0.0
    var frameAgeMs = 0.0
    var repeatsPerSec = 0.0
    var overwrittenPerSec = 0.0
    var lateDroppedPerSec = 0.0
    // Cumulative counters (the report uses last minus first).
    var framesDecoded = 0
    var framesLost = 0
    var framesDropped = 0
    var packetsReceived = 0
    var packetsRecovered = 0
    var audioUnderruns = 0
    var audioOverruns = 0
    var audioLoss = 0
    var audioState = ""
}

nonisolated enum CodecRegression {

    /// The settings value of each codec, in run order.
    static let codecs = ["h264", "h265", "av1", "pyrowave"]

    /// Phases for every codec with HDR off and on.
    static func phases(minutes: Double) -> [PyroWaveExperimentConfig.Phase] {
        codecs.flatMap { codec in
            [false, true].map { hdr in
                PyroWaveExperimentConfig.Phase(name: "\(codec)-hdr-\(hdr ? "on" : "off")", minutes: minutes,
                                               partialDelivery: true, codec: codec, hdr: hdr)
            }
        }
    }

    static func config(minutes: Double = 5, quitWhenDone: Bool = false) -> PyroWaveExperimentConfig {
        PyroWaveExperimentConfig(quitWhenDone: quitWhenDone, phases: phases(minutes: minutes))
    }

    /// The `VideoCodec` a settings value selects.
    static func codec(forSetting s: String) -> VideoCodec? {
        switch s {
        case "h264": return .h264
        case "h265": return .hevc
        case "av1": return .av1
        case "pyrowave": return .pyrowave
        default: return nil
        }
    }

    static func name(_ c: VideoCodec?) -> String {
        switch c {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .pyrowave: return "PyroWave"
        case nil: return "none"
        }
    }

    /// Whether HDR should arrive: asked for, a codec that can carry it, and an HDR display.
    /// The host and app can still refuse it, which is why a miss is a warning, not a failure.
    static func expectsHDR(codecSetting: String, hdrRequested: Bool, displayHDR: Bool) -> Bool {
        hdrRequested && displayHDR && codecSetting != "h264"
    }

    enum Grade: String { case pass = "PASS", warn = "WARN", fail = "FAIL" }

    struct Verdict: Equatable {
        var grade: Grade
        var reasons: [String]
    }

    /// FAIL: no measurement, the stream ended early, the wrong codec arrived, or the frame rate
    /// median is under 90% of the request. WARN: HDR expected but not received, more than 5% of
    /// seconds under 90% of the request, or at least 1 lost frame per minute (Wi-Fi loss is
    /// expected, so it only warns).
    static func verdict(_ r: PyroWaveExperimentReport.PhaseResult) -> Verdict {
        if let failure = r.failure { return Verdict(grade: .fail, reasons: [failure]) }
        var fails: [String] = []
        var warns: [String] = []
        if let setting = r.codec, let want = codec(forSetting: setting), r.receivedCodec != want {
            fails.append("asked for \(name(want)), got \(name(r.receivedCodec))")
        }
        let target = Double(max(r.requestedFps, 1)) * 0.9
        let fps = r.samples.map(\.fps)
        let med = median(fps)
        if med < target { fails.append(String(format: "fps median %.1f under %.0f", med, target)) }
        let low = fps.filter { $0 < target }.count
        if !fps.isEmpty, Double(low) / Double(fps.count) > 0.05 {
            warns.append("\(low) of \(fps.count) seconds under \(Int(target)) fps")
        }
        if r.expectedHdr, r.receivedHdr != true { warns.append("HDR was expected but the picture arrived SDR") }
        if !r.expectedHdr, r.receivedHdr == true { warns.append("HDR arrived although it was not expected") }
        let mins = max(r.seconds, 1) / 60
        let lost = delta(r.samples, \.framesLost)
        if Double(lost) / mins >= 1 { warns.append(String(format: "%.2f lost frames/min", Double(lost) / mins)) }
        if !fails.isEmpty { return Verdict(grade: .fail, reasons: fails + warns) }
        if !warns.isEmpty { return Verdict(grade: .warn, reasons: warns) }
        return Verdict(grade: .pass, reasons: [])
    }

    // MARK: - Report

    static func format(_ r: PyroWaveExperimentReport.PhaseResult) -> String {
        let v = verdict(r)
        var out = "===== \(r.name): \(v.grade.rawValue) =====\n"
        out += "requested    \(r.codec ?? "?") HDR \(r.requestedHdr ? "on" : "off")"
            + " (HDR expected: \(r.expectedHdr ? "yes" : "no"), \(r.requestedFps) fps)\n"
        out += "received     \(name(r.receivedCodec)), picture "
            + "\(r.receivedHdr.map { $0 ? "HDR" : "SDR" } ?? "unknown")"
            + (r.profile.map { ", \($0)" } ?? "") + "\n"
        if !v.reasons.isEmpty { out += "why          " + v.reasons.joined(separator: "; ") + "\n" }
        if r.failure != nil { return out }
        let s = r.samples
        let mins = max(r.seconds, 1) / 60
        func stat(_ k: KeyPath<CodecSecondSample, Double>) -> String {
            let a = s.map { $0[keyPath: k] }
            return String(format: "median %.2f p95 %.2f max %.2f", median(a), percentile(a, 0.95), a.max() ?? 0)
        }
        let target = Double(max(r.requestedFps, 1)) * 0.9
        out += String(format: "window       %.0f s, %d samples\n", r.seconds, s.count)
        out += String(format: "fps          median %.1f, min %.1f, seconds under %.0f: %d\n",
                      median(s.map(\.fps)), s.map(\.fps).min() ?? 0, target, s.filter { $0.fps < target }.count)
        out += "bitrate Mbps \(stat(\.bitrateMbps))\n"
        out += "jitter ms    \(stat(\.jitterMs))\n"
        out += "decode ms    avg: \(stat(\.decodeAvgMs)); per-second max: \(stat(\.decodeMaxMs))\n"
        out += "draw p99 ms  \(stat(\.drawP99Ms)); worst draw interval \(String(format: "%.1f", s.map(\.drawMaxMs).max() ?? 0)) ms\n"
        out += "frame age ms \(stat(\.frameAgeMs))\n"
        out += String(format: "render       repeats %.2f/s, overwritten %.2f/s, late dropped %.2f/s (means)\n",
                      mean(s.map(\.repeatsPerSec)), mean(s.map(\.overwrittenPerSec)), mean(s.map(\.lateDroppedPerSec)))
        let lost = delta(s, \.framesLost)
        out += String(format: "frames       decoded %d, lost %d (%.2f/min), dropped %d\n",
                      delta(s, \.framesDecoded), lost, Double(lost) / mins, delta(s, \.framesDropped))
        out += "packets      received \(delta(s, \.packetsReceived)), FEC recovered \(delta(s, \.packetsRecovered))\n"
        out += "audio        underruns \(delta(s, \.audioUnderruns)), overruns \(delta(s, \.audioOverruns)), "
            + "loss \(delta(s, \.audioLoss)), state at end \(s.last?.audioState ?? "?")\n"
        return out
    }

    static func summaryTable(_ results: [PyroWaveExperimentReport.PhaseResult]) -> String {
        var out = "SUMMARY\nphase                 grade  received        fps med  Mbps med  lost/min  decode ms  why\n"
        for r in results {
            let v = verdict(r)
            let recv = r.failure == nil
                ? "\(name(r.receivedCodec)) \(r.receivedHdr == true ? "HDR" : "SDR")" : "-"
            let mins = max(r.seconds, 1) / 60
            out += String(format: "%-21@ %-6@ %-15@ %7.1f  %8.1f  %8.2f  %9.2f  %@\n",
                          r.name as NSString, v.grade.rawValue as NSString, recv as NSString,
                          median(r.samples.map(\.fps)), median(r.samples.map(\.bitrateMbps)),
                          Double(delta(r.samples, \.framesLost)) / mins,
                          median(r.samples.map(\.decodeAvgMs)),
                          v.reasons.joined(separator: "; ") as NSString)
        }
        return out
    }

    // MARK: - Helpers

    static func delta(_ s: [CodecSecondSample], _ k: KeyPath<CodecSecondSample, Int>) -> Int {
        guard let first = s.first, let last = s.last else { return 0 }
        return last[keyPath: k] - first[keyPath: k]
    }

    static func median(_ a: [Double]) -> Double { percentile(a, 0.5) }

    static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
}

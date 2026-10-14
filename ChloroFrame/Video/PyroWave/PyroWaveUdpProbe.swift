//
//  PyroWaveUdpProbe.swift
//  ChloroFrame
//
//  Pure logic for the PyroWave UDP network test (design/pyrowave-implementation-plan.md D7b,
//  audit check C16). Host reference: vibeshine src/nvhttp.cpp getPyroWaveUdpProbe and
//  src/pyrowave_udp_probe.h. Nothing here touches the network or logs; the socket and HTTPS
//  halves live in PyroWaveUdpProbeSocket.swift and SunshineHTTPClient.runPyroWaveUdpProbe.
//
//  The host sends a 2 second synthetic flow of `packetSize + 48` byte datagrams (32 ASCII token
//  bytes, a big-endian sequence number, filler). This file turns the arrivals plus the host's
//  XML counts into a pass or fail verdict using Vibeshine's calibration thresholds.
//

import Foundation

// MARK: - Request

nonisolated struct PyroWaveUdpProbeRequest: Equatable, Sendable {
    var kbps: Int
    var port: Int
    var packetSize: Int
    var token: String
    /// Frame-shaped schedule (PyroWaveUdpProbeBurstVersion 1): both or neither.
    var fps: Int?
    var paceKbps: Int?

    static let minKbps = 5_000
    static let maxKbps = 3_000_000

    /// nil when the host will accept the request, else why it would not (its 400 text).
    var validationError: String? {
        if kbps < Self.minKbps || kbps > Self.maxKbps { return "bitrate \(kbps) kbps is outside 5000 to 3000000" }
        if port < 1024 || port > 65535 { return "UDP port \(port) is outside 1024 to 65535" }
        if packetSize < 256 || packetSize > 1392 { return "packet size \(packetSize) is outside 256 to 1392" }
        if token.count != 32 || !token.allSatisfy({ "0123456789abcdef".contains($0) }) {
            return "token must be 32 lowercase hex characters"
        }
        if (fps == nil) != (paceKbps == nil) { return "fps and pacekbps must be given together" }
        if let fps, let paceKbps {
            if fps < 10 || fps > 500 { return "fps \(fps) is outside 10 to 500" }
            if paceKbps < kbps || paceKbps > 9_999_999 { return "pace \(paceKbps) kbps is below the bitrate or above 9999999" }
        }
        return nil
    }

    /// The query items after `uniqueid`. Always asks for the handshake form.
    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "kbps", value: String(kbps)),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "packetsize", value: String(packetSize)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "handshake", value: "1"),
        ]
        if let fps, let paceKbps {
            items.append(URLQueryItem(name: "fps", value: String(fps)))
            items.append(URLQueryItem(name: "pacekbps", value: String(paceKbps)))
        }
        return items
    }

    /// A fresh 32 character lowercase hex token.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

// MARK: - Host XML

/// The final XML body of /pyrowave-udp-probe.
nonisolated enum PyroWaveUdpProbeHostResult: Equatable, Sendable {
    case counts(expected: Int, sent: Int, elapsedMs: Double, sendRetries: Int, lastSendError: Int)
    /// `status_code="500"` (handshake or send failed after the headers) or any non 200 root code.
    case failure(code: Int, message: String)
    case malformed

    static func parse(_ data: Data) -> PyroWaveUdpProbeHostResult {
        guard let text = String(data: data, encoding: .utf8), text.contains("<root") else { return .malformed }

        func attr(_ name: String) -> String? {
            guard let rootOpen = text.range(of: "<root"),
                  let rootClose = text.range(of: ">", range: rootOpen.upperBound..<text.endIndex) else { return nil }
            let tag = text[rootOpen.upperBound..<rootClose.lowerBound]
            guard let key = tag.range(of: "\(name)=") else { return nil }
            let rest = tag[key.upperBound...]
            guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            return unescape(String(body[..<end]))
        }
        func element(_ tag: String) -> String? {
            guard let open = text.range(of: "<\(tag)>"),
                  let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
            return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let codeText = attr("status_code"), let code = Int(codeText), code != 200 {
            return .failure(code: code, message: attr("status_message") ?? "the host reported status \(code)")
        }
        guard let expected = element("expected").flatMap({ Int($0) }),
              let sent = element("sent").flatMap({ Int($0) }),
              let elapsed = element("elapsedMs").flatMap({ Double($0) }) else { return .malformed }
        return .counts(expected: expected, sent: sent, elapsedMs: elapsed,
                       sendRetries: element("sendRetries").flatMap { Int($0) } ?? 0,
                       lastSendError: element("lastSendError").flatMap { Int($0) } ?? 0)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Arrivals

nonisolated struct PyroWaveUdpProbeArrival: Equatable, Sendable {
    let seq: Int
    /// Milliseconds on any monotonic clock (only differences matter).
    let ms: Double
}

/// Filters datagrams and keeps the first arrival of each sequence number.
nonisolated struct PyroWaveUdpProbeCollector: Sendable {
    let token: [UInt8]
    /// Anything above this is not a real probe sequence (3 Gbps for 2 s is about 530k packets).
    static let maxSequence = 4_000_000

    private(set) var arrivals: [PyroWaveUdpProbeArrival] = []
    private var seen = Set<Int>()
    private(set) var duplicates = 0
    private(set) var foreign = 0
    private(set) var tooShort = 0

    init(token: String) { self.token = Array(token.utf8) }

    /// Returns true when the datagram was a new probe packet.
    @discardableResult
    mutating func ingest(_ bytes: UnsafeRawBufferPointer, atMs ms: Double) -> Bool {
        // The 32 byte warmups (token only) are shorter than the 36 header bytes and are not data.
        guard bytes.count >= 36 else { tooShort += 1; return false }
        for i in 0..<32 where bytes[i] != token[i] { foreign += 1; return false }
        let seq = Int(bytes[32]) << 24 | Int(bytes[33]) << 16 | Int(bytes[34]) << 8 | Int(bytes[35])
        guard seq < Self.maxSequence else { foreign += 1; return false }
        if !seen.insert(seq).inserted { duplicates += 1; return false }
        arrivals.append(PyroWaveUdpProbeArrival(seq: seq, ms: ms))
        return true
    }

    /// Test helper: the same filter over an owned buffer.
    @discardableResult
    mutating func ingest(_ data: [UInt8], atMs ms: Double) -> Bool {
        data.withUnsafeBytes { ingest($0, atMs: ms) }
    }
}

// MARK: - Planned schedule

/// The send time the host planned for each sequence number, in milliseconds from the start of
/// the 2 s measurement. Mirrors `pyrowave::probe::send` so transit time can be measured against
/// the sender's own plan rather than against a straight line.
nonisolated enum PyroWaveUdpProbeSchedule {
    static let durationMs = 2000

    /// The host's packet budget: `kbps * 2000 / (8 * (packetSize + 134))`.
    static func expectedPackets(kbps: Int, packetSize: Int) -> Int {
        kbps * durationMs / (8 * (packetSize + 134))
    }

    /// Packets per 1 ms group in the frame-shaped schedule (`burst_packets_per_ms`).
    static func packetsPerMs(paceKbps: Int, packetSize: Int, ipv6: Bool) -> Int {
        let wire = (packetSize + 48) + 8 + (ipv6 ? 40 : 20) + 38
        return max(1, paceKbps * 1000 / 8 / 1000 / wire)
    }

    /// `burst` is nil for the default even schedule (1 ms ticks).
    static func plannedMs(seq: Int, expected: Int, packetSize: Int,
                          burst: (fps: Int, paceKbps: Int, ipv6: Bool)?) -> Double {
        guard expected > 0 else { return 0 }
        let s = min(max(seq, 0), expected - 1)
        guard let burst, burst.fps > 0 else {
            // Tick t releases packets below expected * (t + 1) / duration.
            let t = ((s + 1) * durationMs + expected - 1) / expected - 1
            return Double(t)
        }
        let frames = max(1, burst.fps * durationMs / 1000)
        let frame = min(frames - 1, ((s + 1) * frames + expected - 1) / expected - 1)
        let firstOfFrame = expected * frame / frames
        let group = packetsPerMs(paceKbps: burst.paceKbps, packetSize: packetSize, ipv6: burst.ipv6)
        return Double(durationMs * frame / frames) + Double((s - firstOfFrame) / group)
    }
}

// MARK: - Grading

nonisolated struct PyroWaveUdpProbeVerdict: Equatable, Sendable {
    var passed: Bool
    var expected: Int
    var sent: Int
    var received: Int
    var duplicates: Int
    var lossPercent: Double
    var worstWindowLossPercent: Double
    /// p99 minus median of (arrival minus planned send), milliseconds.
    var transitVariationP99Ms: Double
    /// Median transit of the last 10 percent of packets minus the first 10 percent.
    var delayGrowthMs: Double
    var senderElapsedMs: Double
    var sendRetries: Int
    var failures: [String]

    /// One line for the audit row and the report.
    var summary: String {
        let head = passed ? "Network test passed" : "Network test failed"
        let figures = String(format: "loss %.2f%%, worst 100 ms window %.1f%%, jitter p99 %.1f ms, delay growth %.1f ms, received %d of %d",
                             lossPercent, worstWindowLossPercent, transitVariationP99Ms, delayGrowthMs, received, expected)
        if passed { return "\(head): \(figures)." }
        return "\(head) (\(failures.joined(separator: "; "))): \(figures)."
    }
}

nonisolated enum PyroWaveUdpProbeGrader {

    // Vibeshine's calibration policy (docs/pyrowave-protocol.md, "FEC-inclusive recommendations
    // and UDP calibration").
    static let maxAggregateLossPercent = 0.1
    static let maxWindowLossPercent = 1.0
    static let maxTransitVariationMs = 4.0
    static let maxDelayGrowthMs = 2.0
    static let maxDurationErrorFraction = 0.02
    static let windowMs = 100

    /// Grades one run. `arrivals` must hold each sequence number once (the collector does that).
    static func grade(arrivals: [PyroWaveUdpProbeArrival],
                      host: (expected: Int, sent: Int, elapsedMs: Double, sendRetries: Int),
                      packetSize: Int,
                      burst: (fps: Int, paceKbps: Int, ipv6: Bool)?,
                      duplicates: Int = 0) -> PyroWaveUdpProbeVerdict {
        let expected = max(host.expected, 0)
        let valid = arrivals.filter { $0.seq >= 0 && $0.seq < expected }
        var failures: [String] = []

        // Aggregate loss against what the host planned (reliable counts include lost tails).
        let received = valid.count
        let lossPercent = expected > 0 ? Double(expected - received) / Double(expected) * 100 : 100

        // Loss per 100 ms window of the planned schedule (20 windows for 2 s), by planned time.
        let windows = PyroWaveUdpProbeSchedule.durationMs / windowMs
        var planned = [Int](repeating: 0, count: windows)
        var got = [Int](repeating: 0, count: windows)
        func window(of seq: Int) -> Int {
            let ms = PyroWaveUdpProbeSchedule.plannedMs(seq: seq, expected: expected, packetSize: packetSize, burst: burst)
            return min(windows - 1, max(0, Int(ms) / windowMs))
        }
        if expected > 0 {
            for seq in 0..<expected { planned[window(of: seq)] += 1 }
            for a in valid { got[window(of: a.seq)] += 1 }
        }
        var worstWindow = 0.0
        for w in 0..<windows where planned[w] > 0 {
            worstWindow = max(worstWindow, Double(planned[w] - got[w]) / Double(planned[w]) * 100)
        }

        // Relative one way delay: arrival minus planned send. The clocks need not agree because
        // only differences inside the run are used.
        let ordered = valid.sorted { $0.seq < $1.seq }
        let transit = ordered.map {
            $0.ms - PyroWaveUdpProbeSchedule.plannedMs(seq: $0.seq, expected: expected, packetSize: packetSize, burst: burst)
        }
        var variation = 0.0
        var growth = 0.0
        if transit.count >= 20 {
            let sorted = transit.sorted()
            let median = sorted[sorted.count / 2]
            let p99 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.down)))]
            variation = max(0, p99 - median)
            let tenth = max(1, transit.count / 10)
            growth = medianOf(Array(transit.suffix(tenth))) - medianOf(Array(transit.prefix(tenth)))
        }

        if host.sent < expected {
            failures.append("the host sent only \(host.sent) of \(expected) packets (its send buffer or timer fell behind)")
        }
        if received == 0 {
            failures.append("no probe packets arrived (UDP blocked, or a firewall dropped the flow)")
        } else {
            if lossPercent > maxAggregateLossPercent {
                failures.append(String(format: "loss %.2f%% is over %.1f%%", lossPercent, maxAggregateLossPercent))
            }
            if worstWindow > maxWindowLossPercent {
                failures.append(String(format: "a 100 ms window lost %.1f%% (limit %.0f%%)", worstWindow, maxWindowLossPercent))
            }
            if variation > maxTransitVariationMs {
                failures.append(String(format: "p99 transit variation %.1f ms is over %.0f ms", variation, maxTransitVariationMs))
            }
            if growth > maxDelayGrowthMs {
                failures.append(String(format: "delay grew %.1f ms (limit %.0f ms)", growth, maxDelayGrowthMs))
            }
        }
        let duration = Double(PyroWaveUdpProbeSchedule.durationMs)
        if abs(host.elapsedMs - duration) / duration > maxDurationErrorFraction {
            failures.append(String(format: "the host's send took %.0f ms instead of 2000 ms", host.elapsedMs))
        }

        return PyroWaveUdpProbeVerdict(
            passed: failures.isEmpty, expected: expected, sent: host.sent, received: received,
            duplicates: duplicates, lossPercent: lossPercent, worstWindowLossPercent: worstWindow,
            transitVariationP99Ms: variation, delayGrowthMs: growth, senderElapsedMs: host.elapsedMs,
            sendRetries: host.sendRetries, failures: failures)
    }

    private static func medianOf(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }
}

// MARK: - Outcome (what the runner reports)

nonisolated enum PyroWaveNetworkTestOutcome: Equatable, Sendable {
    case graded(PyroWaveUdpProbeVerdict)
    /// The test could not run or complete. Never a pass and never a network fail.
    case unavailable(String)

    var summary: String {
        switch self {
        case .graded(let v): return v.summary
        case .unavailable(let why): return "Network test could not run: \(why)"
        }
    }
}

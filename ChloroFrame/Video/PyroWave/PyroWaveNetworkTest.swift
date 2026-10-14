//
//  PyroWaveNetworkTest.swift
//  ChloroFrame
//
//  Orchestrates the PyroWave UDP network test (D7b, audit check C16): resolves the route,
//  picks the same packet size and Wi-Fi pinning the stream would use, runs the host probe, and
//  keeps the result for the rest of the app session per host, interface and Wi-Fi band. The
//  launch audit reads the cache and never runs the test itself, so a launch is not delayed.
//

import Foundation
import Network

@MainActor
enum PyroWaveNetworkTest {

    struct Entry: Equatable {
        let kbps: Int
        let outcome: PyroWaveNetworkTestOutcome
        let date: Date
    }

    private static var cache: [String: Entry] = [:]

    static func key(hostID: String, interfaceName: String?, band: PyroWaveWiFiBand?) -> String {
        PyroWaveAuditCache.key(hostID: hostID, interfaceName: interfaceName, band: band)
    }

    static func cached(_ key: String) -> Entry? { cache[key] }
    static func store(_ entry: Entry, for key: String) { cache[key] = entry }
    static func removeAll() { cache.removeAll() }

    /// What the audit should be told for this run. A result measured at another bitrate says
    /// nothing about this one, so it counts as not run.
    static func auditFacts(entry: Entry?, requestedKbps: Int) -> (passed: Bool?, summary: String?) {
        guard let entry else { return (nil, nil) }
        guard entry.kbps == requestedKbps else {
            return (nil, "last network test was at \(entry.kbps / 1000) Mbps, not the requested \(requestedKbps / 1000) Mbps")
        }
        switch entry.outcome {
        case .graded(let v): return (v.passed, v.summary)
        case .unavailable(let why): return (nil, "network test could not run: \(why)")
        }
    }

    /// Runs the test at `requestedKbps` (clamped to the host's accepted range). Takes about
    /// 3 seconds. Refused by the host while any stream is active.
    static func run(client: SunshineHTTPClient, display: DisplayConfig, requestedKbps: Int,
                    reason: String, ignoreHostVersionKeys: Bool = false,
                    frameShaped: Bool = true) async -> (outcome: PyroWaveNetworkTestOutcome, kbps: Int) {
        let kbps = min(max(requestedKbps, PyroWaveUdpProbeRequest.minKbps), PyroWaveUdpProbeRequest.maxKbps)
        let address = client.activeAddress

        let (route, link) = await Task.detached(priority: .userInitiated) { () -> (RouteInfo?, PyroWaveMacLink?) in
            let route = RouteResolver.resolve(host: address, port: 48010)
            return (route, route.map { PyroWaveLinkInspector.inspect(interfaceName: $0.interfaceName) })
        }.value
        guard let route else {
            return finish(.unavailable("could not resolve the route to the host"), kbps: kbps,
                          client: client, route: nil, link: nil, reason: reason)
        }
        let cacheKey = key(hostID: client.host.id.uuidString, interfaceName: route.interfaceName, band: link?.wifiBand)

        // Host capability: the version keys come from paired serverinfo (cached by the audit).
        var info = PyroWaveAuditCache.get(cacheKey)
        if info == nil {
            info = try? await client.fetchPairedServerInfo()
            if let info { PyroWaveAuditCache.set(cacheKey, info) }
        }
        guard let info else {
            return finish(.unavailable("could not read the host's paired server info"), kbps: kbps,
                          client: client, route: route, link: link, reason: reason)
        }
        // `ignoreHostVersionKeys` exists only for the DEBUG experiment runner (it asks the host
        // anyway, to learn whether the endpoint exists without advertising itself).
        guard ignoreHostVersionKeys || ((info.udpProbeVersion ?? 0) >= 1 && (info.udpHandshakeVersion ?? 0) >= 1) else {
            func v(_ n: Int?) -> String { n.map(String.init) ?? "absent" }
            return finish(.unavailable("this host does not offer the UDP network test (its paired server info reports probe version \(v(info.udpProbeVersion)) and handshake version \(v(info.udpHandshakeVersion)); a newer Vibeshine build is needed)"),
                          kbps: kbps, client: client, route: route, link: link, reason: reason)
        }

        let networkClass = AddressClassifier.classify(numericHost: route.destination)
        let packetSize = PacketSizePolicy.choose(class: networkClass, family: route.family,
                                                 interfaceMTU: route.interfaceMTU)

        // Frame-shaped schedule when the host supports it: frames at the stream's fps, each
        // paced at the host's link speed (the host paces its own stream at the smaller known
        // link, and ChloroFrame does not announce its link speed).
        var fps: Int?
        var pace: Int?
        if frameShaped, (info.udpProbeBurstVersion ?? 0) >= 1, display.fps >= 10, display.fps <= 500,
           let hostLink = info.linkMbps, hostLink > 0 {
            fps = display.fps
            pace = min(max(hostLink * 1000, kbps), 9_999_999)
        }

        let wifi = NetworkMonitor.shared.wifiInterface
        let pin: UInt32? = (wifi != nil && route.interfaceName == wifi?.name) ? UInt32(wifi!.index) : nil

        let outcome = await client.runPyroWaveUdpProbe(kbps: kbps, packetSize: packetSize, fps: fps,
                                                       paceKbps: pace, route: route, pinInterfaceIndex: pin)
        return finish(outcome, kbps: kbps, client: client, route: route, link: link, reason: reason,
                      extra: "packetSize=\(packetSize) fps=\(fps.map(String.init) ?? "-") paceKbps=\(pace.map(String.init) ?? "-") pinned=\(pin != nil)")
    }

    private static func finish(_ outcome: PyroWaveNetworkTestOutcome, kbps: Int, client: SunshineHTTPClient,
                               route: RouteInfo?, link: PyroWaveMacLink?, reason: String,
                               extra: String = "") -> (PyroWaveNetworkTestOutcome, Int) {
        if let route {
            let k = key(hostID: client.host.id.uuidString, interfaceName: route.interfaceName, band: link?.wifiBand)
            store(Entry(kbps: kbps, outcome: outcome, date: Date()), for: k)
        }
        #if DEBUG
        DebugFileLog.write("[pyrowave-udp-probe] reason=\(reason) host=\(client.host.address) kbps=\(kbps) "
                         + "iface=\(route?.interfaceName ?? "?") \(extra)\n    \(outcome.summary)")
        #endif
        return (outcome, kbps)
    }

    /// The same result as a one-row report for the Test network sheet.
    static func detailLines(_ outcome: PyroWaveNetworkTestOutcome, kbps: Int) -> [String] {
        switch outcome {
        case .unavailable(let why):
            return ["The test could not run at \(kbps / 1000) Mbps.", why]
        case .graded(let v):
            var lines = [v.passed ? "Passed at \(kbps / 1000) Mbps." : "Failed at \(kbps / 1000) Mbps."]
            lines.append(String(format: "Packets: %d received of %d planned (%d sent by the host, %d duplicates ignored).",
                                v.received, v.expected, v.sent, v.duplicates))
            lines.append(String(format: "Loss %.2f%% (limit 0.1%%), worst 100 ms window %.1f%% (limit 1%%).",
                                v.lossPercent, v.worstWindowLossPercent))
            lines.append(String(format: "Jitter p99 %.1f ms (limit 4 ms), delay growth %.1f ms (limit 2 ms).",
                                v.transitVariationP99Ms, v.delayGrowthMs))
            lines.append(String(format: "Host send time %.0f ms, %d send retries.", v.senderElapsedMs, v.sendRetries))
            lines.append(contentsOf: v.failures.map { "Problem: \($0)." })
            return lines
        }
    }
}

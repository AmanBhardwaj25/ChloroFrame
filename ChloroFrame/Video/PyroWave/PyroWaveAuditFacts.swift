//
//  PyroWaveAuditFacts.swift
//  ChloroFrame
//
//  Fact gathering for the readiness audit (design/pyrowave-implementation-plan.md D5b). All the
//  side effects live here (route, CoreWLAN, one paired HTTPS request, sysctl, IOKit); the rules
//  live in the pure PyroWaveReadinessAudit.evaluate.
//
//  Only the paired host info is cached per app session. Everything local (power, thermal, the
//  AWDL setting) is re-read every run and the pure evaluation re-run, because those facts can
//  change between launches and re-evaluating is free.
//

import Foundation
import IOKit.ps
import Metal

// MARK: - Local system facts

nonisolated enum PyroWaveSystemFacts {

    /// `kern.ipc.maxsockbuf` in bytes; nil when unreadable.
    static func maxSocketBufferBytes() -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("kern.ipc.maxsockbuf", &value, &size, nil, 0) == 0 else { return nil }
        // The kernel returns a 4 byte value on some releases and 8 on others.
        if size == MemoryLayout<UInt32>.size { return Int(UInt32(truncatingIfNeeded: value)) }
        return Int(value)
    }

    /// true on battery, false on AC, nil when unknown (desktops report AC).
    static func onBatteryPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return nil }
        return type == kIOPSBatteryPowerValue
    }
}

// MARK: - Cache

/// Paired host info per (host id, route interface, Wi-Fi band), for the app session. A key change
/// (new interface or band) re-fetches.
@MainActor
enum PyroWaveAuditCache {
    private static var hostInfo: [String: PyroWaveHostInfo] = [:]

    static func key(hostID: String, interfaceName: String?, band: PyroWaveWiFiBand?) -> String {
        "\(hostID)|\(interfaceName ?? "?")|\(band.map { "\($0)" } ?? "-")"
    }

    static func get(_ key: String) -> PyroWaveHostInfo? { hostInfo[key] }
    static func set(_ key: String, _ info: PyroWaveHostInfo) { hostInfo[key] = info }
    static func removeAll() { hostInfo.removeAll() }
}

// MARK: - Runner

@MainActor
enum PyroWaveAuditRunner {

    /// Gathers every fact and evaluates. Does one paired HTTPS request unless the host info is
    /// cached; the rest is local syscalls. `forceRefresh` bypasses the cache (the readiness
    /// button). Never throws: anything unreadable becomes an unknown in the report.
    static func run(
        client: SunshineHTTPClient,
        serverInfo: ServerInfo,
        display: DisplayConfig,
        requestedKbps: Int,
        userWantsHDR: Bool,
        forceRefresh: Bool = false,
        reason: String
    ) async -> PyroWaveAuditReport {
        let started = Date()
        let address = client.activeAddress

        // C15 runs alongside the route lookup and the HTTPS request so it adds no wall time of
        // its own beyond whatever it exceeds them by. Cached per stream format for the session.
        async let benchmark = decodeBenchmark(width: display.width, height: display.height)

        // Route and this Mac's link, off the main actor (getaddrinfo and CoreWLAN can block).
        let (route, macLink) = await Task.detached(priority: .userInitiated) { () -> (RouteInfo?, PyroWaveMacLink?) in
            // 48010 is RTSP's default port; only the destination address matters here.
            let route = RouteResolver.resolve(host: address, port: 48010)
            let link = route.map { PyroWaveLinkInspector.inspect(interfaceName: $0.interfaceName) }
            return (route, link)
        }.value

        let cacheKey = PyroWaveAuditCache.key(hostID: client.host.id.uuidString,
                                              interfaceName: route?.interfaceName,
                                              band: macLink?.wifiBand)
        var hostInfo: PyroWaveHostInfo?
        var fetchNote = "cached"
        if !forceRefresh, let cached = PyroWaveAuditCache.get(cacheKey) {
            hostInfo = cached
        } else {
            do {
                let fresh = try await client.fetchPairedServerInfo()
                PyroWaveAuditCache.set(cacheKey, fresh)
                hostInfo = fresh
                fetchNote = "fetched"
            } catch {
                fetchNote = "fetch failed: \(error.localizedDescription)"
            }
        }

        let networkClass = route.map { AddressClassifier.classify(numericHost: $0.destination) }
        var inputs = PyroWaveAuditInputs()
        inputs.gpuSupportsPyroWave = VideoCapabilities.supportsPyroWave
        inputs.hostCodecModeSupport = serverInfo.codecModeSupport
        inputs.hostInfo = hostInfo
        inputs.networkClass = networkClass
        inputs.macLink = macLink
        inputs.requestedKbps = requestedKbps
        inputs.guideKbps = PyroWaveBitrate.defaultKbps(width: display.width, height: display.height, fps: display.fps)
        if let route, let networkClass {
            inputs.packetSize = PacketSizePolicy.choose(class: networkClass, family: route.family,
                                                        interfaceMTU: route.interfaceMTU)
        }
        inputs.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        inputs.thermalState = ProcessInfo.processInfo.thermalState
        inputs.onBatteryPower = PyroWaveSystemFacts.onBatteryPower()
        inputs.maxSocketBufferBytes = PyroWaveSystemFacts.maxSocketBufferBytes()
        inputs.suppressAWDLEnabled = UserDefaults.standard.object(forKey: "suppressAWDLDuringStream") as? Bool ?? true
        inputs.awdlHelperInstalled = AWDLSuppressor.shared.isHelperInstalled
        inputs.userWantsHDR = userWantsHDR
        let bench = await benchmark
        inputs.gpuDecodeMs = bench.ms
        // C16 only reads the session cache; the test itself is the "Test network" action.
        let netFacts = PyroWaveNetworkTest.auditFacts(entry: PyroWaveNetworkTest.cached(cacheKey),
                                                      requestedKbps: requestedKbps)
        inputs.udpTestPassed = netFacts.passed
        inputs.udpTestSummary = netFacts.summary

        let report = PyroWaveReadinessAudit.evaluate(inputs)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        #if DEBUG
        var lines = "[ChloroFrame][pyrowave-audit] reason=\(reason) host=\(client.host.address) address=\(address) "
            + "dest=\(route?.destination ?? "?") iface=\(route?.interfaceName ?? "?") "
            + "kind=\(macLink.map { "\($0.kind)" } ?? "?") band=\(macLink?.wifiBand.map { "\($0)" } ?? "unknown") "
            + "macLinkMbps=\(macLink?.linkMbps.map(String.init) ?? "?") hostInfo=\(fetchNote) "
            + "requestedKbps=\(requestedKbps) decodeBenchmark=\(bench.note) elapsedMs=\(ms) blocked=\(report.blocked)"
        for line in report.logLines { lines += "\n    \(line)" }
        DebugFileLog.write(lines)
        #endif
        StreamLog.log("[ChloroFrame][pyrowave-audit] reason=\(reason) blocked=\(report.blocked) elapsedMs=\(ms) \(report.logLines.joined(separator: "; "))")
        return report
    }

    /// C15 input: average GPU decode ms at this stream size (8-bit 4:2:0 until D8 and D9), from
    /// the session cache or a fresh benchmark. nil when it could not be measured, which the
    /// audit reports as an unknown, never as a slow GPU.
    nonisolated private static func decodeBenchmark(width: Int, height: Int) async -> (ms: Double?, note: String) {
        guard VideoCapabilities.supportsPyroWave, let device = MTLCreateSystemDefaultDevice() else {
            return (nil, "skipped (no supported GPU)")
        }
        let format = PyroWaveStreamFormat(width: width, height: height, chroma444: false, bitDepth: 8)
        if let cached = PyroWaveBenchmarkCache.averageGPUMs(for: format) {
            return (cached, String(format: "%.2fms cached", cached))
        }
        do {
            let m = try await PyroWaveDecodeBenchmark.measure(device: device, format: format)
            PyroWaveBenchmarkCache.store(m.averageGPUMs, for: format)
            return (m.averageGPUMs, String(format: "%.2fms max=%.2fms wall=%.0fms", m.averageGPUMs, m.maxGPUMs, m.wallMs))
        } catch {
            return (nil, "failed: \(error)")
        }
    }
}

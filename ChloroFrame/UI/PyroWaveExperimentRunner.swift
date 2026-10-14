//
//  PyroWaveExperimentRunner.swift
//  ChloroFrame
//
//  DEBUG builds only. Runs the D10 live A/B inside the app: for each phase it sets the partial
//  delivery flag and software loss, starts a stream on the saved host through the normal launch
//  flow, waits a fixed window after the first decoded frame, snapshots the counters and
//  `netstat -s -p udp`, stops the stream, and writes a report.
//
//  Start it with Stream > Run PyroWave Experiment (default D10 phases) or by writing a config to
//  /tmp/chloroframe-experiment.json before launching the app. Report:
//  /tmp/chloroframe-experiment-results.txt (also copied to /tmp/chloroframe-debug.log).
//
//  The whole file is compiled out of Release builds, so no experiment path or logging exists in
//  the shipped app.
//

#if DEBUG
import Foundation
import AppKit
import os

extension Notification.Name {
    static let runPyroWaveExperiment = Notification.Name("runPyroWaveExperiment")
}

/// Loss settings the receive loop reads when a session starts (DEBUG only).
nonisolated enum PyroWaveExperimentControl {
    private static let state = OSAllocatedUnfairLock(initialState: (percent: 0.0, burst: 1, injected: 0))

    static func setLoss(percent: Double, burstLength: Int) {
        state.withLock { $0.percent = percent; $0.burst = max(1, burstLength); $0.injected = 0 }
    }

    /// An injector for a new receive loop, or nil when no loss is configured.
    static func makeInjector() -> PyroWaveLossInjector? {
        let s = state.withLock { $0 }
        return s.percent > 0 ? PyroWaveLossInjector(percent: s.percent, burstLength: s.burst) : nil
    }

    static func addInjected(_ n: Int) { state.withLock { $0.injected += n } }
    static var injected: Int { state.withLock { $0.injected } }
}

@MainActor
final class PyroWaveExperimentRunner {
    static let shared = PyroWaveExperimentRunner()
    static let configPath = "/tmp/chloroframe-experiment.json"
    static let resultsPath = "/tmp/chloroframe-experiment-results.txt"

    private(set) var isRunning = false
    private var config: PyroWaveExperimentConfig?
    private var retriesLeft = 0

    /// App to launch for the host connection flow while an experiment runs.
    func appToLaunch(from apps: [SunshineApp]) -> SunshineApp? {
        guard isRunning, let config else { return nil }
        if let title = config.appTitle, let app = apps.first(where: { $0.title == title }) { return app }
        return apps.first
    }

    /// The host connection flow asks this before offering the already running app dialog.
    func consumeRetry() -> Bool {
        guard isRunning, retriesLeft > 0 else { return false }
        retriesLeft -= 1
        return true
    }

    // MARK: - Entry points

    /// At app launch: runs the file's config when it exists (and removes it, so a relaunch does
    /// not repeat the run).
    func startIfRequested(hosts: @escaping () -> [Host], present: @escaping (Host) -> Void,
                          dismiss: @escaping () -> Void, streamState: StreamState) async {
        guard !isRunning, let data = FileManager.default.contents(atPath: Self.configPath) else { return }
        try? FileManager.default.removeItem(atPath: Self.configPath)
        guard let cfg = try? JSONDecoder().decode(PyroWaveExperimentConfig.self, from: data) else {
            DebugFileLog.write("[experiment] \(Self.configPath) is not a valid config, ignoring")
            return
        }
        // Give the host list and window a moment to settle.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await run(cfg, hosts: hosts, present: present, dismiss: dismiss, streamState: streamState)
    }

    func run(_ cfg: PyroWaveExperimentConfig, hosts: () -> [Host], present: @escaping (Host) -> Void,
             dismiss: @escaping () -> Void, streamState: StreamState) async {
        guard !isRunning else { return }
        isRunning = true
        config = cfg
        let storedChroma444 = UserDefaults.standard.object(forKey: "pyroWave444")
        if let want = cfg.chroma444 { UserDefaults.standard.set(want, forKey: "pyroWave444") }
        let storedHDR = UserDefaults.standard.object(forKey: "enableHDR")
        if let want = cfg.hdr { UserDefaults.standard.set(want, forKey: "enableHDR") }
        // Puts back what the run changed. Called by the defer and again right before quitWhenDone
        // terminates, because NSApp.terminate exits the process and the defer never runs then.
        // Running it twice is harmless.
        let restoreSettings = {
            if cfg.hdr != nil {
                if let storedHDR { UserDefaults.standard.set(storedHDR, forKey: "enableHDR") }
                else { UserDefaults.standard.removeObject(forKey: "enableHDR") }
            }
            if cfg.chroma444 != nil {
                if let storedChroma444 { UserDefaults.standard.set(storedChroma444, forKey: "pyroWave444") }
                else { UserDefaults.standard.removeObject(forKey: "pyroWave444") }
            }
            UserDefaults.standard.removeObject(forKey: "pyroWavePartialDelivery")
            PyroWaveExperimentControl.setLoss(percent: 0, burstLength: 1)
        }
        defer {
            isRunning = false
            config = nil
            restoreSettings()
        }

        let all = hosts()
        let host = cfg.hostName.flatMap { name in
            all.first { $0.name == name || $0.address == name }
        } ?? all.first
        guard let host else {
            write("experiment aborted: no saved host\n")
            return
        }
        DebugFileLog.write("[experiment] start: host \(host.name), \(cfg.phases.count) phases")

        var results: [PyroWaveExperimentReport.PhaseResult] = []
        var text = "PyroWave experiment \(Date())\nhost \(host.name)\n\n"

        if cfg.udpProbeRepeats > 0 {
            if streamState.isActive { streamState.stop(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
            text += await runUdpProbes(cfg, host: host)
            write(text)
        }

        for phase in cfg.phases {
            var result = await runPhase(phase, cfg: cfg, host: host, present: present, dismiss: dismiss,
                                        streamState: streamState)
            // The host occasionally answers RTSP without PyroWave (seen right after a previous
            // session ended), which downgrades the stream to HEVC. One retry is enough.
            if let failure = result.failure, failure.contains("not PyroWave") {
                DebugFileLog.write("[experiment] phase \(phase.name) was not PyroWave, retrying once")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                result = await runPhase(phase, cfg: cfg, host: host, present: present, dismiss: dismiss,
                                        streamState: streamState)
            }
            results.append(result)
            let block = PyroWaveExperimentReport.format(result)
            text += block + "\n"
            // Keep the file current so a crash still leaves finished phases behind.
            write(text)
            DebugFileLog.write("[experiment] phase \(phase.name) done")
        }
        text += PyroWaveExperimentReport.summaryTable(results)
        write(text)
        DebugFileLog.write("[experiment] finished, results in \(Self.resultsPath)")
        NSSound(named: "Glass")?.play()
        if cfg.quitWhenDone {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            restoreSettings()
            UserDefaults.standard.synchronize()
            NSApp.terminate(nil)
        }
    }

    // MARK: - UDP network test (D7b)

    /// Runs the host UDP probe `cfg.udpProbeRepeats` times with no stream active and returns the
    /// report text. The probe needs the paired HTTPS port, which a serverinfo call sets.
    private func runUdpProbes(_ cfg: PyroWaveExperimentConfig, host: Host) async -> String {
        let client = SunshineHTTPClient(host: host)
        let info = try? await client.fetchServerInfo()
        let display = DisplayConfig.detect()
        let override = UserDefaults.standard.integer(forKey: "streamOverrideBitrate")
        let profile = PyroWaveNegotiation.chooseProfile(
            userWants444: UserDefaults.standard.bool(forKey: "pyroWave444"),
            userWantsHDR: UserDefaults.standard.bool(forKey: "enableHDR") && display.hdr,
            hostSCM: info?.codecModeSupport ?? 0)
        let kbps = cfg.udpProbeKbps
            ?? (override > 0 ? override
                : PyroWaveBitrate.defaultKbps(width: display.width, height: display.height, fps: display.fps,
                                                      hdr10: profile.tenBit, yuv444: profile.chroma444))
        var text = "UDP network test (D7b), \(cfg.udpProbeRepeats) run(s) at \(kbps / 1000) Mbps\n"
        for n in 1...cfg.udpProbeRepeats {
            let result = await PyroWaveNetworkTest.run(client: client, display: display, requestedKbps: kbps,
                                                       reason: "experiment \(n)",
                                                       ignoreHostVersionKeys: cfg.udpProbeIgnoreVersionKeys,
                                                       frameShaped: cfg.udpProbeFrameShaped)
            text += "  run \(n): \(result.outcome.summary)\n"
            DebugFileLog.write("[experiment] udp probe \(n)/\(cfg.udpProbeRepeats) done")
            if n < cfg.udpProbeRepeats { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return text + "\n"
    }

    // MARK: - One phase

    private func runPhase(_ phase: PyroWaveExperimentConfig.Phase, cfg: PyroWaveExperimentConfig,
                          host: Host, present: @escaping (Host) -> Void, dismiss: @escaping () -> Void,
                          streamState: StreamState) async -> PyroWaveExperimentReport.PhaseResult {
        var result = PyroWaveExperimentReport.PhaseResult(
            name: phase.name, partialDelivery: phase.partialDelivery, lossPercent: phase.lossPercent,
            burstLength: phase.burstLength, seconds: 0, fps: [],
            start: PyroWaveExperimentSample(), end: PyroWaveExperimentSample(), failure: nil)

        // The receiver reads the flag and loss when its session starts.
        UserDefaults.standard.set(phase.partialDelivery, forKey: "pyroWavePartialDelivery")
        PyroWaveExperimentControl.setLoss(percent: phase.lossPercent, burstLength: phase.burstLength)
        retriesLeft = 2

        // Make sure nothing is streaming, then connect through the normal flow.
        if streamState.isActive { streamState.stop(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
        dismiss()
        try? await Task.sleep(nanoseconds: 500_000_000)
        present(host)

        // Wait for the stream to start and decode its first frame.
        let startDeadline = Date().addingTimeInterval(cfg.startupTimeoutSeconds)
        var stats: StreamStatsCollector?
        while Date() < startDeadline {
            if streamState.isActive, let s = streamState.stats, let c = s.pyroWaveStatsProvider?(), c.decoded > 0 {
                stats = s
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let stats else {
            result.failure = streamState.isActive
                ? "the stream started but is not PyroWave (downgraded to HEVC, or no frame decoded)"
                : "no stream within \(Int(cfg.startupTimeoutSeconds)) s (host unreachable, app launch failed, or pairing needed)"
            if streamState.isActive { streamState.stop() }
            dismiss()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return result
        }

        try? await Task.sleep(nanoseconds: UInt64(cfg.skipSeconds * 1_000_000_000))
        let netBefore = Self.udpStats()
        result.start = sample(stats: stats, udp: netBefore)
        PyroWaveExperimentControl.setLoss(percent: phase.lossPercent, burstLength: phase.burstLength)
        let injectedBase = PyroWaveExperimentControl.injected
        let t0 = Date()
        let end = t0.addingTimeInterval(phase.minutes * 60)

        var aborted: String?
        while Date() < end {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard streamState.isActive else {
                aborted = "the stream ended after \(Int(Date().timeIntervalSince(t0))) s"
                break
            }
            result.fps.append(stats.current.measFps)
        }
        result.seconds = Date().timeIntervalSince(t0)
        let picture = stats.receivedHdr.map { $0 ? "HDR (PQ)" : "SDR" } ?? "unknown"
        result.profile = "\(stats.pyroWaveProfileLabel ?? "?"), picture \(picture)"
        result.end = sample(stats: stats, udp: Self.udpStats())
        result.start.injectedDrops = 0
        result.end.injectedDrops = PyroWaveExperimentControl.injected - injectedBase
        if let aborted { result.failure = aborted }

        if streamState.isActive { streamState.stop() }
        dismiss()
        try? await Task.sleep(nanoseconds: 4_000_000_000)   // let the host tear the session down
        return result
    }

    private func sample(stats: StreamStatsCollector, udp: (received: Int, fullSocketDrops: Int))
        -> PyroWaveExperimentSample {
        var s = stats.experimentSnapshot()
        if let c = stats.pyroWaveStatsProvider?() {
            s.decoded = c.decoded
            s.partialDecoded = c.partialDecoded
            s.blocksSkipped = c.blocksSkipped
            s.mailboxReplaced = c.mailboxReplaced
            s.parseRejects = c.parseRejects
            s.pushRejects = c.pushRejects
            s.incomplete = c.incomplete
            s.gpuMsAvg = c.decodeAvgMs
            s.gpuMsMax = c.gpuMsMax
        }
        s.udpDatagramsReceived = udp.received
        s.udpFullSocketDrops = udp.fullSocketDrops
        return s
    }

    private static func udpStats() -> (received: Int, fullSocketDrops: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-s", "-p", "udp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return UDPStatsParser.parse(String(decoding: data, as: UTF8.self))
    }

    private func write(_ text: String) {
        try? text.write(toFile: Self.resultsPath, atomically: true, encoding: .utf8)
    }
}
#endif

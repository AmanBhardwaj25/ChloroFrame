//
//  HostConnectionView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI
import Metal

// MARK: - Connection flow state machine
// StreamError lives in StreamState.swift so ContentView can reference it too.

private enum FlowPhase {
    case connecting
    case needsPairing(ServerInfo)
    case pairingShowPin(ServerInfo, String)   // String = the PIN we generated
    case appList(ServerInfo, [SunshineApp])
    case launching(SunshineApp)
    case negotiating(SunshineApp, SunshineHTTPClient.LaunchResult)
    case failed(Error)
    // Distinct from .failed: carries the app + serverInfo so the error view can offer
    // "Stop Running App & Retry" when the failure is SunshineError.appAlreadyRunning.
    case launchFailed(SunshineApp, ServerInfo, Error)
    // PyroWave audit passed its blockers but has warnings: ask before streaming (D5b).
    case pyroWaveWarnings(SunshineApp, ServerInfo, PyroWaveAuditReport)
}

// What to do about PyroWave when launch continues after the audit (D5b).
private enum PyroWaveLaunchChoice {
    case auto          // not applicable, or the audit passed
    case useHEVC       // blocker failed, or the user chose HEVC
}

// The in-flight connection for this sheet, so Cancel can tear down whatever is blocking
// (RTSP request, ENet connect) and a late success cannot start a stream the user abandoned.
private final class ConnectAttempt {
    private(set) var isCancelled = false
    var rtsp:      RTSPClient?
    var transport: StreamTransport?

    func cancel() {
        isCancelled = true
        rtsp?.cancel()
        transport?.stop(reason: "connect cancelled")
        rtsp = nil
        transport = nil
    }
}

// Spinner + message for the waiting phases, with a Cancel that is always available and a
// note once the wait runs long. A new phase is a new view, so the stall timer restarts.
private struct ConnectProgressView<Accessory: View>: View {
    let message: String
    let onCancel: () -> Void
    @ViewBuilder let accessory: Accessory

    private static var stallSeconds: Int { 15 }
    @State private var stalled = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(message)
                .foregroundStyle(.secondary)
            accessory
            if stalled {
                Text("This is taking longer than usual. The host may not be responding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 360, height: 220)
        .padding()
        .task {
            try? await Task.sleep(for: .seconds(Self.stallSeconds))
            stalled = true
        }
    }
}

// MARK: - Root view

struct HostConnectionView: View {

    let host: Host
    @Environment(\.dismiss) private var dismiss
    @Environment(StreamState.self) private var streamState

    @AppStorage("preferredCodec")            private var preferredCodec      = "h264"
    @AppStorage("enableHDR")                 private var enableHDR           = false
    @AppStorage("pyroWave444")               private var pyroWave444         = false
    // Stream overrides — empty/0 means "auto-detect from display"
    @AppStorage("streamOverrideResolution")  private var overrideResolution  = ""   // "WxH" or ""
    @AppStorage("streamOverrideFPS")         private var overrideFPS         = 0
    @AppStorage("streamOverrideBitrate")     private var overrideBitrate     = 0    // kbps

    @State private var client: SunshineHTTPClient
    @State private var phase: FlowPhase = .connecting
    @State private var showStreamSettings = false
    // PyroWave readiness (D5b): the one-line HEVC fallback notice, the report behind its Details
    // button, and the app-list "Check PyroWave readiness" action.
    @State private var pyroWaveFallbackReport: PyroWaveAuditReport?
    @State private var showFallbackDetails = false
    @State private var pyroWaveCheckReport: PyroWaveAuditReport?
    @State private var pyroWaveChecking = false
    // PyroWave UDP network test (D7b), "Test network" in the app list.
    @State private var networkTestResult: (outcome: PyroWaveNetworkTestOutcome, kbps: Int)?
    @State private var networkTesting = false
    @State private var attempt = ConnectAttempt()

    init(host: Host) {
        self.host = host
        _client = State(initialValue: SunshineHTTPClient(host: host))
    }

    var body: some View {
        Group {
            switch phase {
            case .connecting:
                connectingView
            case .needsPairing(let info):
                needsPairingView(info)
            case .pairingShowPin(let info, let pin):
                pairingShowPinView(info, pin: pin)
            case .appList(let info, let apps):
                appListView(info, apps: apps)
            case .launching(let app):
                launchingView(app)
            case .negotiating(let app, let result):
                negotiatingView(app, result: result)
            case .failed(let error):
                errorView(error)
            case .launchFailed(let app, let info, let error):
                launchFailedView(app, serverInfo: info, error: error)
            case .pyroWaveWarnings(let app, let info, let report):
                PyroWaveWarningsView(
                    report: report,
                    onStream:  { Task { await performLaunch(app: app, serverInfo: info, pyroWave: .auto) } },
                    onUseHEVC: { Task { await performLaunch(app: app, serverInfo: info, pyroWave: .useHEVC) } },
                    onCancel:  { Task { await connect() } }
                )
            }
        }
        .task { await connect() }
        .sheet(isPresented: $showFallbackDetails) {
            if let report = pyroWaveFallbackReport {
                PyroWaveAuditReportView(report: report, onClose: { showFallbackDetails = false })
            }
        }
        .sheet(isPresented: Binding(
            get: { networkTestResult != nil },
            set: { if !$0 { networkTestResult = nil } }
        )) {
            if let result = networkTestResult {
                PyroWaveNetworkTestView(outcome: result.outcome, kbps: result.kbps,
                                        onClose: { networkTestResult = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { pyroWaveCheckReport != nil },
            set: { if !$0 { pyroWaveCheckReport = nil } }
        )) {
            if let report = pyroWaveCheckReport {
                PyroWaveAuditReportView(report: report, title: "PyroWave readiness for \(host.name)",
                                        onClose: { pyroWaveCheckReport = nil })
            }
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        ConnectProgressView(message: "Connecting to \(host.name)…", onCancel: cancelAttempt) {
            EmptyView()
        }
    }

    // Abandon whatever is in flight and close the sheet. Does not /cancel the host app: a
    // stalled connect to a running game must not quit that game. The host drops the unused
    // launch on its own after ping_timeout.
    private func cancelAttempt() {
        attempt.cancel()
        dismiss()
    }

    // MARK: - Needs pairing

    private func needsPairingView(_ info: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(info)

            Text("This host isn't paired yet. Click **Pair** — a PIN will appear that you'll enter in Sunshine's web UI.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pair") {
                    Task { await startPairing(info: info) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380, height: 220)
    }

    // MARK: - Show PIN to user

    private func pairingShowPinView(_ info: ServerInfo, pin: String) -> some View {
        VStack(spacing: 20) {
            header(info)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(spacing: 8) {
                Text("Enter this PIN in Sunshine's web UI")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(pin)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(12)
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for confirmation…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 380, height: 260)
    }

    // MARK: - App list

    private func appListView(_ info: ServerInfo, apps: [SunshineApp]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.hostname)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(info.gpuType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showStreamSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(overrideResolution.isEmpty && overrideFPS == 0 && overrideBitrate == 0
                                         ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Stream settings")
                .popover(isPresented: $showStreamSettings, arrowEdge: .bottom) {
                    StreamSettingsPopover(
                        overrideResolution: $overrideResolution,
                        overrideFPS:        $overrideFPS,
                        overrideBitrate:    $overrideBitrate,
                        maxCustomMbps:      preferredCodec == "pyrowave" ? 2000 : 500
                    )
                }

                Button {
                    client.unpair()
                    Task { await connect() }
                } label: {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unpair this host")

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if apps.isEmpty {
                Spacer()
                Text("No apps available")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(apps) { app in
                            AppCard(
                                app:         app,
                                isRunning:   info.currentGame != 0 && info.currentGame == app.id,
                                fetchBoxArt: { await client.fetchBoxArt(id: app.id) },
                                onLaunch:    { Task { await launch(app: app, serverInfo: info) } },
                                onStop:      { Task { await stopRunningApp(id: app.id) } }
                            )
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button("Check PyroWave readiness") {
                    Task { await checkPyroWaveReadiness(serverInfo: info, apps: apps) }
                }
                .disabled(pyroWaveChecking)
                .help("Runs the PyroWave readiness checks for this host and shows every result, even when PyroWave is not the selected codec.")
                if pyroWaveChecking { ProgressView().controlSize(.small) }
                Button("Test network") {
                    Task { await runNetworkTest(serverInfo: info, apps: apps) }
                }
                .disabled(networkTesting || pyroWaveChecking)
                .help("Sends about 3 seconds of test traffic from the host at the PyroWave bitrate and grades loss and jitter on this path. The host refuses while a stream is running.")
                if networkTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing, about 3 seconds").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 500)
    }

    // MARK: - Error

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.red)

            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                Button("Retry") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 360, height: 220)
        .padding()
    }

    // MARK: - Launch error (with recovery for a stuck "app already running" session)

    private func launchFailedView(_ app: SunshineApp, serverInfo: ServerInfo, error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.red)

            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                if isAppAlreadyRunning(error) {
                    Button("Stop Running App & Retry") {
                        Task { await stopAndRetry(app: app, serverInfo: serverInfo) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Retry") { Task { await launch(app: app, serverInfo: serverInfo) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 360, height: 220)
        .padding()
    }

    private func isAppAlreadyRunning(_ error: Error) -> Bool {
        guard let sunshineError = error as? SunshineError else { return false }
        if case .appAlreadyRunning = sunshineError { return true }
        return false
    }

    // MARK: - Launching

    private func launchingView(_ app: SunshineApp) -> some View {
        ConnectProgressView(message: "Launching \(app.title)…", onCancel: cancelAttempt) {
            pyroWaveFallbackNotice
        }
    }

    // One line shown when the PyroWave audit sent this launch to HEVC (D5b), with the full report
    // behind Details. Empty for every other launch.
    @ViewBuilder
    private var pyroWaveFallbackNotice: some View {
        if let line = pyroWaveFallbackReport?.fallbackHeadline {
            VStack(spacing: 4) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Details") { showFallbackDetails = true }
                    .font(.caption)
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - RTSP negotiating

    private func negotiatingView(_ app: SunshineApp, result: SunshineHTTPClient.LaunchResult) -> some View {
        ConnectProgressView(message: "Connecting stream for \(app.title)…", onCancel: cancelAttempt) {
            pyroWaveFallbackNotice
        }
    }

    // MARK: - Shared header component

    private func header(_ info: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.hostname)
                .font(.title2)
                .fontWeight(.semibold)
            Text(info.gpuType)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func connect() async {
        phase = .connecting
        do {
            let info = try await client.fetchServerInfo()
            if client.isPaired() {
                let apps = try await client.fetchAppList()
                phase = .appList(info, apps)
                #if DEBUG
                // Live experiment (DEBUG only): launch without a click.
                if let app = PyroWaveExperimentRunner.shared.appToLaunch(from: apps) {
                    await launch(app: app, serverInfo: info)
                }
                #endif
            } else {
                phase = .needsPairing(info)
            }
        } catch {
            phase = .failed(error)
        }
    }

    private func startPairing(info: ServerInfo) async {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        phase = .pairingShowPin(info, pin)
        do {
            try await client.pair(pin: pin)
            let apps = try await client.fetchAppList()
            phase = .appList(info, apps)
        } catch {
            print("Pairing failed: \(error)")
            phase = .failed(error)
        }
    }

    private func launch(app: SunshineApp, serverInfo: ServerInfo) async {
        phase = .launching(app)
        pyroWaveFallbackReport = nil
        guard preferredCodec == "pyrowave" else {
            await performLaunch(app: app, serverInfo: serverInfo, pyroWave: .auto)
            return
        }

        // PyroWave readiness audit (D5b). It runs here, BEFORE /launch: nothing may run between
        // /launch and RTSP, where Sunshine's session times out.
        let display = buildDisplayConfig(base: DisplayConfig.detect())
        let report = await PyroWaveAuditRunner.run(
            client: client, serverInfo: serverInfo, display: display,
            requestedKbps: pyroWaveRequestedKbps(display: display, serverInfo: serverInfo,
                                                 appSupportsHDR: app.isHDRSupported),
            userWantsHDR: pyroWaveWantsHDR(display: display, appSupportsHDR: app.isHDRSupported),
            userWants444: pyroWave444, reason: "launch"
        )
        if report.blocked {
            pyroWaveFallbackReport = report
            await performLaunch(app: app, serverInfo: serverInfo, pyroWave: .useHEVC)
        } else if !report.warnings.isEmpty {
            #if DEBUG
            if PyroWaveExperimentRunner.shared.isRunning {
                await performLaunch(app: app, serverInfo: serverInfo, pyroWave: .auto)
                return
            }
            #endif
            phase = .pyroWaveWarnings(app, serverInfo, report)
        } else {
            await performLaunch(app: app, serverInfo: serverInfo, pyroWave: .auto)
        }
    }

    // The total bitrate a PyroWave launch will request: the user's override, else the PyroWave
    // default. Mirrors the codec == .pyrowave branch of performLaunch.
    private func pyroWaveRequestedKbps(display: DisplayConfig, serverInfo: ServerInfo, appSupportsHDR: Bool) -> Int {
        let profile = pyroWaveProfile(display: display, serverInfo: serverInfo, appSupportsHDR: appSupportsHDR)
        return overrideBitrate > 0
            ? overrideBitrate
            : PyroWaveBitrate.defaultKbps(width: display.width, height: display.height, fps: display.fps,
                                          hdr10: profile.tenBit, yuv444: profile.chroma444)
    }

    // HDR counts as asked for when the setting is on, the display can show it and the app
    // supports it: the same `wantHdr` performLaunch computes. Callers with no app chosen yet
    // (the readiness button, Test network) pass `PyroWaveNegotiation.hostAppsSupportHDR`, so
    // they land on the same profile and bitrate as the launch and the C16 cache matches.
    private func pyroWaveWantsHDR(display: DisplayConfig, appSupportsHDR: Bool) -> Bool {
        enableHDR && display.hdr && appSupportsHDR
    }

    // The profile this launch will use (D8 and D9): 4:4:4 and 10-bit only when asked for and
    // offered by the host.
    private func pyroWaveProfile(display: DisplayConfig, serverInfo: ServerInfo, appSupportsHDR: Bool) -> PyroWaveNegotiation.Profile {
        PyroWaveNegotiation.chooseProfile(
            userWants444: pyroWave444,
            userWantsHDR: pyroWaveWantsHDR(display: display, appSupportsHDR: appSupportsHDR),
            hostSCM: serverInfo.codecModeSupport)
    }

    private func checkPyroWaveReadiness(serverInfo: ServerInfo, apps: [SunshineApp]) async {
        pyroWaveChecking = true
        defer { pyroWaveChecking = false }
        let display = buildDisplayConfig(base: DisplayConfig.detect())
        let appsHDR = PyroWaveNegotiation.hostAppsSupportHDR(apps.map(\.isHDRSupported))
        pyroWaveCheckReport = await PyroWaveAuditRunner.run(
            client: client, serverInfo: serverInfo, display: display,
            requestedKbps: pyroWaveRequestedKbps(display: display, serverInfo: serverInfo, appSupportsHDR: appsHDR),
            userWantsHDR: pyroWaveWantsHDR(display: display, appSupportsHDR: appsHDR),
            userWants444: pyroWave444, forceRefresh: true, reason: "button"
        )
    }

    private func runNetworkTest(serverInfo: ServerInfo, apps: [SunshineApp]) async {
        networkTesting = true
        defer { networkTesting = false }
        let display = buildDisplayConfig(base: DisplayConfig.detect())
        let appsHDR = PyroWaveNegotiation.hostAppsSupportHDR(apps.map(\.isHDRSupported))
        networkTestResult = await PyroWaveNetworkTest.run(
            client: client, display: display,
            requestedKbps: pyroWaveRequestedKbps(display: display, serverInfo: serverInfo, appSupportsHDR: appsHDR),
            reason: "button")
    }

    private func performLaunch(app: SunshineApp, serverInfo: ServerInfo, pyroWave: PyroWaveLaunchChoice) async {
        // Held locally: the sheet may be dismissed (Cancel) while this task is suspended.
        let attempt = self.attempt
        guard !attempt.isCancelled else { return }
        phase = .launching(app)
        let base    = DisplayConfig.detect()
        let display = buildDisplayConfig(base: base)
        // Compute enableHdr here so the same value goes into both the HTTP /launch request
        // (hdrMode — Apollo uses this to enable Windows HDR before encoder setup) and the
        // subsequent RTSP negotiation (dynamicRangeMode). Using different values in the two
        // legs is what caused the "P010/BT.2020 but not PQ" mismatch.
        // Whether the user wants HDR and the display/app can carry it. AV1 HDR needs
        // host AV1 Main10; SDR AV1 needs Main8. If AV1+HDR is requested but the host
        // lacks Main10, fall through to HEVC (which still gets HDR if the host supports
        // it) rather than silently dropping HDR.
        let wantHdr = enableHDR && display.hdr && app.isHDRSupported
        // AV1 only when the local device has a HW AV1 decoder AND the host advertises the
        // matching AV1 profile (Main10 for HDR, Main8 for SDR); otherwise fall back to
        // HEVC. (RTSP DESCRIBE applies a second downgrade if the host's actual SDP lacks
        // AV1/90000.) H.264/HEVC behavior is unchanged.
        let codec: VideoCodec
        switch preferredCodec {
        case "h264": codec = .h264
        // PyroWave only when this Mac can decode it and the host advertises the 8-bit 4:2:0
        // profile. Remote routes are downgraded to HEVC in RTSP negotiation (decision Q4),
        // where the route is known. Otherwise falls through to HEVC like AV1 does.
        case "pyrowave" where pyroWave == .auto
                           && VideoCapabilities.supportsPyroWave && serverInfo.supportsPyroWave420:
            codec = .pyrowave
        case "av1" where VideoCapabilities.supportsAV1Hardware
                      && (wantHdr ? serverInfo.supportsAV1Main10 : serverInfo.supportsAV1Main8):
            codec = .av1
        default:     codec = .hevc
        }
        // PyroWave (D9): HDR10 only when the host advertises a 10-bit profile; otherwise the
        // stream is 8-bit SDR and HDR is off here, which keeps /launch hdrMode and RTSP in
        // agreement. The host's 0x010e message later says whether the 10-bit picture is PQ.
        // Same helper as the audit and Test network, so all of them agree on the profile.
        let pwProfile = pyroWaveProfile(display: display, serverInfo: serverInfo,
                                        appSupportsHDR: app.isHDRSupported)
        let enableHdr = codec == .pyrowave ? (wantHdr && pwProfile.tenBit) : (wantHdr && (codec == .hevc || codec == .av1))
        #if DEBUG
        DebugFileLog.write("[ChloroFrame][launch] preferredCodec=\(preferredCodec) supportsPyroWave=\(VideoCapabilities.supportsPyroWave) "
                  + "scm=0x\(String(serverInfo.codecModeSupport, radix: 16)) hostPyroWave420=\(serverInfo.supportsPyroWave420) "
                  + "-> codec=\(codec) enableHdr=\(enableHdr) overrideBitrate=\(overrideBitrate) autoBitrate=\(display.bitrate)")
        #endif
        // PyroWave needs hundreds of Mbps, so without a user override it gets its own default
        // instead of the 80 Mbps cap in DisplayConfig. The ordinary auto value rides along as
        // the fallback an RTSP downgrade to HEVC restores.
        var streamDisplay = display
        var fallbackBitrate: Int? = nil
        // D8: 4:4:4 only for a PyroWave stream, only when the host advertises it.
        let use444 = codec == .pyrowave && pwProfile.chroma444
        #if DEBUG
        if codec == .pyrowave {
            DebugFileLog.write("[ChloroFrame][launch] pyrowave userWants444=\(pyroWave444) userWantsHDR=\(wantHdr) "
                             + "hostOffers444=\(serverInfo.supportsPyroWave444) hostOffersHDR10=\(serverInfo.supportsPyroWaveHDR10) "
                             + "hostOffersHDR10_444=\(serverInfo.supportsPyroWaveHDR10_444) profile=\(pwProfile.label)"
                             + (pwProfile.fallbackReason.map { " (fallback: \($0))" } ?? ""))
        }
        #endif
        if codec == .pyrowave {
            // A stored custom bitrate above the non-PyroWave cap (500 Mbps) is only valid for
            // PyroWave; sending it to HEVC makes the host's NVENC reject the session. Fall back
            // to the auto value in that case.
            let autoBitrate = DisplayConfig(width: display.width, height: display.height,
                                            fps: display.fps, hdr: display.hdr).bitrate
            fallbackBitrate = display.bitrate > 500_000 ? autoBitrate : display.bitrate
            if overrideBitrate == 0 {
                streamDisplay = DisplayConfig(
                    width: display.width, height: display.height, fps: display.fps, hdr: display.hdr,
                    bitrateOverride: PyroWaveBitrate.defaultKbps(
                        width: display.width, height: display.height, fps: display.fps,
                        hdr10: enableHdr, yuv444: use444
                    )
                )
            }
        }
        do {
            let result = try await client.launchApp(id: app.id, display: display, hdrMode: enableHdr)
            guard !attempt.isCancelled else { return }
            // Show the negotiating UI immediately, then start RTSP in the same task.
            // Do NOT use a SwiftUI .task for this — the view scheduling delay (~2s) causes
            // Sunshine's RTSP session to time out before we send SETUP.
            phase = .negotiating(app, result)
            await negotiate(app: app, result: result, display: streamDisplay, codec: codec, hdr: enableHdr, yuv444: use444, fallbackBitrateKbps: fallbackBitrate, attempt: attempt)
        } catch {
            guard !attempt.isCancelled else { return }
            #if DEBUG
            if isAppAlreadyRunning(error), PyroWaveExperimentRunner.shared.consumeRetry() {
                await stopAndRetry(app: app, serverInfo: serverInfo)
                return
            }
            #endif
            phase = .launchFailed(app, serverInfo, error)
        }
    }

    // Force-stop whatever the host thinks is running (falling back to the target app's own id
    // if serverInfo is stale and doesn't know it) and retry the same launch.
    private func stopAndRetry(app: SunshineApp, serverInfo: ServerInfo) async {
        let runningId = serverInfo.currentGame != 0 ? serverInfo.currentGame : app.id
        await client.cancelApp(id: runningId)
        await launch(app: app, serverInfo: serverInfo)
    }

    // Stop a specific app from the app-list "running" badge, then refresh so its badge clears.
    private func stopRunningApp(id: Int) async {
        await client.cancelApp(id: id)
        await connect()
    }

    private func negotiate(app: SunshineApp, result: SunshineHTTPClient.LaunchResult, display: DisplayConfig, codec: VideoCodec, hdr enableHdr: Bool, yuv444: Bool = false, fallbackBitrateKbps: Int? = nil, attempt: ConnectAttempt) async {
        guard let sessionURL = URL(string: result.sessionUrl) else {
            phase = .failed(RTSPError.badURL); return
        }
        let config = StreamConfig(
            width:   display.width,
            height:  display.height,
            fps:     display.fps,
            bitrate: display.bitrate,
            codec:   codec,
            hdr:     enableHdr,
            yuv444:  yuv444,
            fallbackBitrateKbps: fallbackBitrateKbps
        )
        AppLogger.shared.log(
            "stream config \(config.width)×\(config.height)@\(config.fps) \(config.bitrate)kbps hdr=\(enableHdr) (display_edr=\(display.hdr))",
            "negotiate", "display"
        )

        // PyroWave: start compiling the decode shaders now, in parallel with RTSP, so the decoder
        // the transport builds before Start A/B is a cache hit.
        if codec == .pyrowave, let device = MTLCreateSystemDefaultDevice() {
            PyroWaveDevice.warmUp(device: device)
        }

        let rtsp = RTSPClient()
        attempt.rtsp = rtsp
        do {
            let stream = try await rtsp.negotiate(sessionURL: sessionURL, config: config)
            attempt.rtsp = nil
            guard !attempt.isCancelled else { return }

            guard let r = MetalVideoRenderer(isHdr: stream.dynamicRangeMode != 0) else {
                AppLogger.shared.log("renderer creation failed", "metal", "renderer")
                phase = .failed(StreamError.rendererUnavailable)
                return
            }

            let t  = StreamTransport(descriptor: stream, config: config, rikey: result.rikey)
            let ih = InputHandler(transport: t)
            let ct = ControllerTranslator(transport: t)
            r.stats = t.stats
            r.setStreamFps(config.fps)
            t.onVideoTexture = { pixelBuffer, pts in r.enqueueFrame(pixelBuffer, pts: pts) }
            // PyroWave decodes into planar textures on the renderer's own device.
            t.metalDevice = r.device
            t.onPlanarFrame = { frame, pts in r.enqueueFrame(.planar(frame), pts: pts) }
            t.onClockReset = { r.resetClockAnchor() }
            t.onENetDisconnect = {
                Task { @MainActor in
                    streamState.didDisconnect(error: StreamError.controlDisconnected)
                }
            }
            t.onNoMediaReceived = {
                Task { @MainActor in
                    streamState.didDisconnect(error: StreamError.noMediaReceived)
                }
            }
            t.onAudioRecoveryStatusChange = { status in
                Task { @MainActor in
                    streamState.setAudioRecoveryStatus(status)
                }
            }

            attempt.transport = t
            try await t.start()
            // Cancel already stopped the transport; do not hand a dead stream to the window.
            guard !attempt.isCancelled else { return }
            attempt.transport = nil

            // Hand off to the main window and dismiss this sheet.
            let codecName: String
            switch stream.videoCodec {
            case .h264: codecName = "H.264"
            case .hevc: codecName = "H.265"
            case .av1:  codecName = "AV1"
            case .pyrowave: codecName = "PyroWave"
            }
            let appId     = app.id
            let clientRef = client
            streamState.activate(
                transport:    t,
                renderer:     r,
                inputHandler: ih,
                controller:   ct,
                appName:      app.title,
                codecInfo:    "\(codecName) · \(display.width)×\(display.height)@\(display.fps) · \(stream.serverHost)",
                onCancel:     { await clientRef.cancelApp(id: appId) }
            )
            dismiss()
        } catch {
            attempt.rtsp = nil
            attempt.transport = nil
            guard !attempt.isCancelled else { return }
            phase = .failed(error)
        }
    }

    // Merge auto-detected display config with any user overrides from AppStorage.
    private func buildDisplayConfig(base: DisplayConfig) -> DisplayConfig {
        let parts = overrideResolution.split(separator: "x")
        let w = parts.count == 2 ? (Int(parts[0]).map { $0 & ~1 } ?? 0) : 0
        let h = parts.count == 2 ? (Int(parts[1]).map { $0 & ~1 } ?? 0) : 0

        let width   = w > 0 ? w : base.width
        let height  = h > 0 ? h : base.height
        let fps     = overrideFPS     > 0 ? overrideFPS     : base.fps
        let bitrate = overrideBitrate > 0 ? overrideBitrate : 0   // 0 → auto-compute
        return DisplayConfig(width: width, height: height, fps: fps, hdr: base.hdr, bitrateOverride: bitrate)
    }
}

// MARK: - Stream Settings Popover

private struct StreamSettingsPopover: View {
    @Binding var overrideResolution: String
    @Binding var overrideFPS: Int
    @Binding var overrideBitrate: Int
    // 500 normally, 2000 when PyroWave is the preferred codec (decision Q5).
    let maxCustomMbps: Int

    // Fetched on appear — owned by the popover so there's no parent-to-child timing race.
    @State private var availableModes: [DisplayResolution] = []

    private var selectedMode: DisplayResolution? {
        availableModes.first { $0.id == overrideResolution }
    }

    private var availableFPS: [Int] {
        if let mode = selectedMode { return mode.refreshRates }
        return Array(Set(availableModes.flatMap { $0.refreshRates })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stream Settings")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Divider()

            Form {
                Section {
                    Picker("Resolution", selection: $overrideResolution) {
                        Text("Auto").tag("")
                        if !availableModes.isEmpty { Divider() }
                        ForEach(availableModes) { mode in
                            Text(mode.label).tag(mode.id)
                        }
                    }
                    .onChange(of: overrideResolution) { _, _ in
                        // Clear FPS override when resolution changes —
                        // the previous fps value may not exist in the new mode.
                        overrideFPS = 0
                    }

                    Picker("Frame Rate", selection: $overrideFPS) {
                        Text("Auto").tag(0)
                        if !availableFPS.isEmpty { Divider() }
                        ForEach(availableFPS, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    Picker("Bitrate", selection: $overrideBitrate) {
                        Text("Auto").tag(0)
                        Divider()
                        Text("5 Mbps").tag(5_000)
                        Text("10 Mbps").tag(10_000)
                        Text("20 Mbps").tag(20_000)
                        Text("30 Mbps").tag(30_000)
                        Text("50 Mbps").tag(50_000)
                        Text("80 Mbps").tag(80_000)
                    }

                    // Custom bitrate (Mbps). Overrides the picker above; 0 = Auto.
                    // Clamped to 500 Mbps for now (experimental); 2000 when PyroWave is the
                    // preferred codec, which needs hundreds of Mbps.
                    TextField("Custom (Mbps)", value: Binding(
                        get: { overrideBitrate / 1000 },
                        set: { overrideBitrate = max(0, min($0, maxCustomMbps)) * 1000 }
                    ), format: .number)
                    .help("Type a custom target bitrate in Mbps (max \(maxCustomMbps)). Takes effect on the next connect.")
                }

                Section {
                    Button("Reset to Auto") {
                        overrideResolution = ""
                        overrideFPS        = 0
                        overrideBitrate    = 0
                    }
                    .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 300)
        .padding(.bottom, 8)
        .task {
            // Fetch display modes on appear so timing doesn't depend on the parent.
            availableModes = DisplayConfig.availableResolutions()
        }
    }
}

// MARK: - App Card

private struct AppCard: View {
    let app: SunshineApp
    let isRunning: Bool
    let fetchBoxArt: () async -> NSImage?
    let onLaunch: () -> Void
    let onStop: () -> Void

    @State private var isHovered = false
    @State private var boxArt: NSImage?

    // Box art is portrait (roughly 2:3). Card width drives layout.
    private let cardW: CGFloat = 120
    private var cardH: CGFloat { cardW * 1.5 }

    var body: some View {
        // A plain ZStack + .onTapGesture (rather than wrapping everything in a Button) so the
        // "stop" Button below can sit on top of it as its own tap target — a Button nested
        // inside another Button doesn't get its own independent tap on macOS/tvOS.
        ZStack(alignment: .bottom) {
            // Art or placeholder
            Group {
                if let img = boxArt {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color("CFSurface")
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Color.accentColor.opacity(0.4))
                }
            }
            .frame(width: cardW, height: cardH)
            .clipped()

            // Title bar
            VStack(spacing: 2) {
                Text(app.title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                HStack(spacing: 4) {
                    if isRunning {
                        Text("RUNNING")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if app.isHDRSupported {
                        Text("HDR")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color("CFGold"), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            if isRunning {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onStop) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                                .background(Circle().fill(.black.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                        .help("Stop this app on the host")
                        .padding(6)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: cardW, height: cardH)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isHovered ? Color.accentColor.opacity(0.7) : Color(.separatorColor).opacity(0.5),
                    lineWidth: isHovered ? 1.5 : 0.5
                )
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onLaunch)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .task {
            boxArt = await fetchBoxArt()
        }
    }
}

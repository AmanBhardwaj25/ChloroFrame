//
//  HostConnectionView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI

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
}

// MARK: - Root view

struct HostConnectionView: View {

    let host: Host
    @Environment(\.dismiss) private var dismiss
    @Environment(StreamState.self) private var streamState

    @AppStorage("preferredCodec")            private var preferredCodec      = "h264"
    @AppStorage("enableHDR")                 private var enableHDR           = false
    // Stream overrides — empty/0 means "auto-detect from display"
    @AppStorage("streamOverrideResolution")  private var overrideResolution  = ""   // "WxH" or ""
    @AppStorage("streamOverrideFPS")         private var overrideFPS         = 0
    @AppStorage("streamOverrideBitrate")     private var overrideBitrate     = 0    // kbps

    @State private var client: SunshineHTTPClient
    @State private var phase: FlowPhase = .connecting
    @State private var showStreamSettings = false

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
            }
        }
        .task { await connect() }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(host.name)…")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 200)
        .padding()
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
                        overrideBitrate:    $overrideBitrate
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
                            AppCard(app: app, fetchBoxArt: {
                                await client.fetchBoxArt(id: app.id)
                            }) {
                                Task { await launch(app: app) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 520, height: 460)
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

    // MARK: - Launching

    private func launchingView(_ app: SunshineApp) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Launching \(app.title)…")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 200)
        .padding()
    }

    // MARK: - RTSP negotiating

    private func negotiatingView(_ app: SunshineApp, result: SunshineHTTPClient.LaunchResult) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Connecting stream for \(app.title)…")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 200)
        .padding()
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

    private func launch(app: SunshineApp) async {
        phase = .launching(app)
        let base    = DisplayConfig.detect()
        let display = buildDisplayConfig(base: base)
        // Compute enableHdr here so the same value goes into both the HTTP /launch request
        // (hdrMode — Apollo uses this to enable Windows HDR before encoder setup) and the
        // subsequent RTSP negotiation (dynamicRangeMode). Using different values in the two
        // legs is what caused the "P010/BT.2020 but not PQ" mismatch.
        let codec: VideoCodec = preferredCodec == "h264" ? .h264 : .hevc
        let enableHdr = enableHDR && display.hdr && codec == .hevc && app.isHDRSupported
        do {
            let result = try await client.launchApp(id: app.id, display: display, hdrMode: enableHdr)
            // Show the negotiating UI immediately, then start RTSP in the same task.
            // Do NOT use a SwiftUI .task for this — the view scheduling delay (~2s) causes
            // Sunshine's RTSP session to time out before we send SETUP.
            phase = .negotiating(app, result)
            await negotiate(app: app, result: result, display: display, codec: codec, hdr: enableHdr)
        } catch {
            phase = .failed(error)
        }
    }

    private func negotiate(app: SunshineApp, result: SunshineHTTPClient.LaunchResult, display: DisplayConfig, codec: VideoCodec, hdr enableHdr: Bool) async {
        guard let sessionURL = URL(string: result.sessionUrl) else {
            phase = .failed(RTSPError.badURL); return
        }
        let config = StreamConfig(
            width:   display.width,
            height:  display.height,
            fps:     display.fps,
            bitrate: display.bitrate,
            codec:   codec,
            hdr:     enableHdr
        )
        AppLogger.shared.log(
            "stream config \(config.width)×\(config.height)@\(config.fps) \(config.bitrate)kbps hdr=\(enableHdr) (display_edr=\(display.hdr))",
            "negotiate", "display"
        )

        let rtsp = RTSPClient()
        do {
            let stream = try await rtsp.negotiate(sessionURL: sessionURL, config: config)

            guard let r = MetalVideoRenderer(isHdr: stream.dynamicRangeMode != 0) else {
                AppLogger.shared.log("renderer creation failed", "metal", "renderer")
                phase = .failed(StreamError.rendererUnavailable)
                return
            }

            let t  = StreamTransport(descriptor: stream, config: config, rikey: result.rikey)
            let ih = InputHandler(transport: t)
            r.stats = t.stats
            r.setStreamFps(config.fps)
            t.onVideoTexture = { pixelBuffer, pts in r.enqueueFrame(pixelBuffer, pts: pts) }
            t.onClockReset = { r.resetClockAnchor() }
            t.onENetDisconnect = {
                Task { @MainActor in
                    streamState.didDisconnect(error: StreamError.controlDisconnected)
                }
            }

            try await t.start()

            // Hand off to the main window and dismiss this sheet.
            let codecName: String
            switch stream.videoCodec {
            case .h264: codecName = "H.264"
            case .hevc: codecName = "H.265"
            default:    codecName = "AV1"
            }
            let appId     = app.id
            let clientRef = client
            streamState.activate(
                transport:    t,
                renderer:     r,
                inputHandler: ih,
                appName:      app.title,
                codecInfo:    "\(codecName) · \(display.width)×\(display.height)@\(display.fps) · \(stream.serverHost)",
                onCancel:     { await clientRef.cancelApp(id: appId) }
            )
            dismiss()
        } catch {
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
    let fetchBoxArt: () async -> NSImage?
    let onLaunch: () -> Void

    @State private var isHovered = false
    @State private var boxArt: NSImage?

    // Box art is portrait (roughly 2:3). Card width drives layout.
    private let cardW: CGFloat = 120
    private var cardH: CGFloat { cardW * 1.5 }

    var body: some View {
        Button(action: onLaunch) {
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

                    if app.isHDRSupported {
                        Text("HDR")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color("CFGold"), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .task {
            boxArt = await fetchBoxArt()
        }
    }
}

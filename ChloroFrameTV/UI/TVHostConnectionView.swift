//
//  TVHostConnectionView.swift
//  ChloroFrameTV
//
//  Connection / pairing / negotiation flow (Phases 3-4). Reuses the shared
//  SunshineHTTPClient and RTSPClient. This phase intentionally stops at a
//  successful RTSP negotiation (the StreamDescriptor): no video, audio, or input
//  yet. Those arrive in Phases 5-8.
//
//  Because a successful negotiate() sends RTSP PLAY, the host begins streaming. We
//  are not consuming it, so the "Stop session" action cancels the app on the host
//  to avoid leaving it streaming into the void.
//

import SwiftUI

struct TVHostConnectionView: View {
    let host: Host

    @Environment(\.dismiss) private var dismiss
    @State private var client: SunshineHTTPClient
    @State private var phase: Phase = .connecting

    // tvOS MVP defaults: 1080p60 H.264 SDR (port plan first-correctness target).
    private let codec: VideoCodec = .h264

    enum Phase {
        case connecting
        case needsPairing(ServerInfo)
        case showPin(ServerInfo, String)
        case appList(ServerInfo, [SunshineApp])
        case launching(SunshineApp)
        case negotiating(SunshineApp)
        case streaming(SunshineApp, StreamTransport, MetalVideoRenderer, TVControllerTranslator, Int)  // Int = fps
        case failed(String)
    }

    init(host: Host) {
        self.host = host
        _client = State(initialValue: SunshineHTTPClient(host: host))
    }

    var body: some View {
        Group {
            if case .streaming(let app, let transport, let renderer, let controller, let fps) = phase {
                streamingView(app: app, transport: transport, renderer: renderer, controller: controller, fps: fps)
            } else {
                ZStack {
                    TVTheme.background.ignoresSafeArea()
                    content
                        .padding(80)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await connect() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .connecting:
            status("Connecting to \(host.name.isEmpty ? host.address : host.name)…", spinner: true)
        case .needsPairing(let info):
            needsPairing(info)
        case .showPin(_, let pin):
            showPin(pin)
        case .appList(let info, let apps):
            appList(info, apps)
        case .launching(let app):
            status("Launching \(app.title)…", spinner: true)
        case .negotiating(let app):
            status("Negotiating stream for \(app.title)…", spinner: true)
        case .streaming:
            // Rendered fullscreen in `body`; nothing to show inside the padded chrome.
            Color.black
        case .failed(let message):
            failed(message)
        }
    }

    // MARK: - Screens

    private func status(_ text: String, spinner: Bool) -> some View {
        VStack(spacing: 28) {
            if spinner { ProgressView().controlSize(.large) }
            Text(text)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private func needsPairing(_ info: ServerInfo) -> some View {
        VStack(spacing: 28) {
            Text(info.hostname)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            Text("This host isn't paired yet. Start pairing, then enter the PIN shown here in Sunshine's web UI.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button {
                Task { await startPairing(info: info) }
            } label: {
                Label("Start Pairing", systemImage: "link")
                    .padding(.horizontal, 16)
            }
        }
    }

    private func showPin(_ pin: String) -> some View {
        VStack(spacing: 24) {
            Text("Enter this PIN in Sunshine's web UI")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(pin)
                .font(.system(size: 120, weight: .bold, design: .monospaced))
                .tracking(20)
                .foregroundStyle(TVTheme.gold)
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for confirmation…")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func appList(_ info: ServerInfo, _ apps: [SunshineApp]) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.hostname)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Text(info.gpuType)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if apps.isEmpty {
                Text("No apps available on this host.")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 28)],
                        spacing: 28
                    ) {
                        ForEach(apps) { app in
                            Button {
                                Task { await launch(app: app) }
                            } label: {
                                TVAppTile(app: app)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func streamingView(app: SunshineApp, transport: StreamTransport, renderer: MetalVideoRenderer, controller: TVControllerTranslator, fps: Int) -> some View {
        TVMetalVideoView(renderer: renderer, streamFps: fps)
            .ignoresSafeArea()
            // Menu/Back on the remote stops the session: release the pad, tear down the
            // transport, cancel the app on the host, and pop back to the host list.
            .onExitCommand {
                controller.releaseAll()
                controller.stop()
                transport.stop()
                Task {
                    await client.cancelApp(id: app.id)
                    dismiss()
                }
            }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 24) {
                Button("Back") { dismiss() }
                Button("Retry") { Task { await connect() } }
            }
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
            phase = .failed(error.localizedDescription)
        }
    }

    private func startPairing(info: ServerInfo) async {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        phase = .showPin(info, pin)
        do {
            try await client.pair(pin: pin)
            let apps = try await client.fetchAppList()
            phase = .appList(info, apps)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func launch(app: SunshineApp) async {
        phase = .launching(app)
        let display = DisplayConfig.detect()   // tvOS 1080p60 SDR preset
        do {
            let result = try await client.launchApp(id: app.id, display: display, hdrMode: false)
            phase = .negotiating(app)
            await negotiate(app: app, result: result, display: display)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func negotiate(app: SunshineApp, result: SunshineHTTPClient.LaunchResult, display: DisplayConfig) async {
        guard let sessionURL = URL(string: result.sessionUrl) else {
            phase = .failed("Invalid RTSP session URL")
            return
        }
        let config = StreamConfig(
            width:   display.width,
            height:  display.height,
            fps:     display.fps,
            bitrate: display.bitrate,
            codec:   codec,
            hdr:     false
        )
        do {
            let stream = try await RTSPClient().negotiate(sessionURL: sessionURL, config: config)

            guard let renderer = MetalVideoRenderer(isHdr: stream.dynamicRangeMode != 0) else {
                await client.cancelApp(id: app.id)
                phase = .failed("Metal renderer unavailable")
                return
            }
            let transport = StreamTransport(descriptor: stream, config: config, rikey: result.rikey)
            renderer.stats = transport.stats
            renderer.setStreamFps(config.fps)
            transport.onVideoTexture = { [weak renderer] pixelBuffer, pts in
                renderer?.enqueueFrame(pixelBuffer, pts: pts)
            }
            transport.onClockReset = { [weak renderer] in renderer?.resetClockAnchor() }

            try await transport.start()
            let controller = TVControllerTranslator(transport: transport)
            controller.start()
            phase = .streaming(app, transport, renderer, controller, config.fps)
        } catch {
            await client.cancelApp(id: app.id)
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct TVAppTile: View {
    let app: SunshineApp

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(TVTheme.gold)
            Text(app.title)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if app.isHDRSupported {
                Text("HDR")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(TVTheme.gold, in: Capsule())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(TVTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

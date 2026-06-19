//
//  SettingsView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("preferredCodec") private var preferredCodec = "h264"
    // Hardware Acceleration: inert toggle (nothing read this value, and the decoder *requires*
    // a hardware decoder via RequireHardwareAcceleratedVideoDecoder, so it can't be turned off
    // without a software-fallback path). Commented out rather than deleted.
    // @AppStorage("hardwareAcceleration") private var hardwareAcceleration = true
    // Low Latency Mode: inert toggle (nothing read this value; the decoder always runs in
    // RealTime mode). Commented out rather than deleted in case we wire it up later.
    // @AppStorage("lowLatencyMode") private var lowLatencyMode = true
    @AppStorage("enableHDR") private var enableHDR = false
    @AppStorage("useSwiftFEC") private var useSwiftFEC = false
    @AppStorage("useAppleAudioDecoder") private var useAppleAudioDecoder = false
    @AppStorage("preferSmootherAudio") private var preferSmootherAudio = false
    @AppStorage("suppressAWDLDuringStream") private var suppressAWDL = true

    @State private var awdlReady = AWDLSuppressor.shared.isHelperInstalled
    @State private var awdlSetupError: String?
    @State private var showKeybinds = false
    @State private var showController = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Video") {
                Picker("Codec", selection: $preferredCodec) {
                    Text("H.264 (AVC)").tag("h264")
                    Text("H.265 (HEVC)").tag("h265")
                }
                .help("H.264 is broadly supported; H.265 is better quality at lower bitrates but requires HEVC decoding support")

                // Toggle("Hardware Acceleration", isOn: $hardwareAcceleration)
                //     .help("Use Apple Silicon's dedicated media engines")

                // Toggle("Low Latency Mode", isOn: $lowLatencyMode)
                //     .help("Minimize buffering for responsive input")

                Toggle("HDR (requires HEVC + host HDR on)", isOn: $enableHDR)
                    .help("Request HDR10 (BT.2020 PQ) encoding. Enable only when the host system has HDR active — requires HEVC codec. Takes effect on the next connect.")
                    .disabled(preferredCodec != "h265")
            }

            section("Audio") {
                Toggle("Decode Opus with Apple AudioToolbox", isOn: $useAppleAudioDecoder)
                    .help("Decode the host's Opus audio with macOS's built-in decoder (AudioConverter) instead of the bundled libopus. 100% Apple frameworks. Takes effect on the next connect.")

                Toggle("Prefer smoother audio (trades latency)", isOn: $preferSmootherAudio)
                    .help("Keep more audio buffered and shrink it gently so jitter bursts don't cause dropouts. Adds a little audio latency. Leave off for lowest latency. Takes effect on the next connect.")
            }

            section("Network") {
                Toggle("Suppress AWDL During Stream", isOn: $suppressAWDL)
                    .help("Brings awdl0 down while streaming to prevent AirDrop/Handoff from competing for WiFi airtime. Automatically restored when the stream ends.")

                if suppressAWDL {
                    if awdlReady { awdlReinstallRow } else { awdlSetupRow }
                }

                Toggle("Use Swift FEC", isOn: $useSwiftFEC)
                    .help("Use the pure-Swift Reed-Solomon implementation instead of the C (nanors) path. Both are functionally identical; this is for diagnostic comparison.")
            }

            section("Input") {
                HStack {
                    Button("Setup custom keybinds…") { showKeybinds = true }
                        .help("Remap the command, option, control, and fn keys for the host. Takes effect on the next connect.")
                    Spacer()
                }
                HStack {
                    Button("Controller…") { showController = true }
                        .help("Detect connected controllers, see their inputs live, and set up remaps.")
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { awdlReady = AWDLSuppressor.shared.isHelperInstalled }
        .sheet(isPresented: $showKeybinds) { KeybindEditorView() }
        .sheet(isPresented: $showController) { ControllerMapperView() }
    }

    // A grouped section that grows to fit its contents (no scroll view, so the window can be
    // sized exactly to whatever is on screen).
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var awdlSetupRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            if let err = awdlSetupError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Requires privileged helper installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install Helper…") {
                awdlSetupError = nil
                do {
                    try AWDLSuppressor.shared.installHelper()
                    awdlReady = AWDLSuppressor.shared.isHelperInstalled
                } catch {
                    awdlSetupError = error.localizedDescription
                }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }

    // Shown when the helper reports installed. A Debug rebuild silently staleness the
    // registered daemon (status stays .enabled but it won't launch), so offer a re-register.
    private var awdlReinstallRow: some View {
        HStack(spacing: 6) {
            if let err = awdlSetupError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Helper installed. If AWDL stays active, re-register.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-register…") {
                awdlSetupError = nil
                do {
                    try AWDLSuppressor.shared.installHelper(force: true)
                    awdlReady = AWDLSuppressor.shared.isHelperInstalled
                } catch {
                    awdlSetupError = error.localizedDescription
                }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }
}

#Preview {
    SettingsView()
}

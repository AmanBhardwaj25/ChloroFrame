//
//  SettingsView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("preferredCodec") private var preferredCodec = "h264"
    @AppStorage("hardwareAcceleration") private var hardwareAcceleration = true
    @AppStorage("lowLatencyMode") private var lowLatencyMode = true
    @AppStorage("enableHDR") private var enableHDR = false
    @AppStorage("useSwiftFEC") private var useSwiftFEC = false
    @AppStorage("suppressAWDLDuringStream") private var suppressAWDL = true

    @State private var awdlReady = AWDLSuppressor.shared.isHelperInstalled
    @State private var awdlSetupError: String?

    var body: some View {
        Form {
            Section("Video") {
                Picker("Codec", selection: $preferredCodec) {
                    Text("H.264 (AVC)").tag("h264")
                    Text("H.265 (HEVC)").tag("h265")
                }
                .help("H.264 is broadly supported; H.265 is better quality at lower bitrates but requires HEVC decoding support")

                Toggle("Hardware Acceleration", isOn: $hardwareAcceleration)
                    .help("Use Apple Silicon's dedicated media engines")

                Toggle("Low Latency Mode", isOn: $lowLatencyMode)
                    .help("Minimize buffering for responsive input")

                Toggle("HDR (requires HEVC + host HDR on)", isOn: $enableHDR)
                    .help("Request HDR10 (BT.2020 PQ) encoding. Enable only when the host system has HDR active — requires HEVC codec. Takes effect on the next connect.")
                    .disabled(preferredCodec != "h265")
            }

            Section("Network") {
                Toggle("Suppress AWDL During Stream", isOn: $suppressAWDL)
                    .help("Brings awdl0 down while streaming to prevent AirDrop/Handoff from competing for WiFi airtime. Automatically restored when the stream ends.")

                if suppressAWDL && !awdlReady {
                    awdlSetupRow
                }

                Toggle("Use Swift FEC", isOn: $useSwiftFEC)
                    .help("Use the pure-Swift Reed-Solomon implementation instead of the C (nanors) path. Both are functionally identical; this is for diagnostic comparison.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: suppressAWDL && !awdlReady ? 370 : 340)
        .onAppear { awdlReady = AWDLSuppressor.shared.isHelperInstalled }
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
}

#Preview {
    SettingsView()
}

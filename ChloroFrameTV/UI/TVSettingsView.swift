//
//  TVSettingsView.swift
//  ChloroFrameTV
//
//  Stream settings: resolution, frame rate, HDR. Persisted via @AppStorage and read by
//  TVHostConnectionView when launching. Codec is derived from HDR (HDR requires HEVC;
//  otherwise H.264, the safe default).
//

import SwiftUI

// Shared @AppStorage keys, also read by TVHostConnectionView.
enum TVStreamSettings {
    static let resolutionKey = "tvResolution"
    static let fpsKey        = "tvFps"
    static let hdrKey        = "tvHDR"
    static let bitrateKey    = "tvBitrate"
    static let codecKey      = "tvCodec"   // "h264" | "h265"

    static let defaultResolution = "1920x1080"
    static let defaultFps        = 60
    static let defaultBitrate    = 0   // 0 = auto (computed from resolution/fps)
    static let defaultCodec      = "h264"

    static let resolutions: [(label: String, value: String)] = [
        ("1080p (1920×1080)", "1920x1080"),
        ("1440p (2560×1440)", "2560x1440"),
        ("4K (3840×2160)",    "3840x2160"),
    ]
    static let fpsOptions = [30, 60, 120]
    static let bitrateOptions: [(label: String, value: Int)] = [
        ("Auto",    0),
        ("10 Mbps", 10_000),
        ("20 Mbps", 20_000),
        ("30 Mbps", 30_000),
        ("50 Mbps", 50_000),
        ("80 Mbps", 80_000),
    ]
}

struct TVSettingsView: View {
    @AppStorage(TVStreamSettings.resolutionKey) private var resolution = TVStreamSettings.defaultResolution
    @AppStorage(TVStreamSettings.fpsKey)        private var fps        = TVStreamSettings.defaultFps
    @AppStorage(TVStreamSettings.bitrateKey)    private var bitrate    = TVStreamSettings.defaultBitrate
    @AppStorage(TVStreamSettings.hdrKey)        private var hdr        = false
    @AppStorage(TVStreamSettings.codecKey)      private var codec      = TVStreamSettings.defaultCodec

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(TVStreamSettings.resolutions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }

                    Picker("Frame Rate", selection: $fps) {
                        ForEach(TVStreamSettings.fpsOptions, id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }

                    Picker("Bitrate", selection: $bitrate) {
                        ForEach(TVStreamSettings.bitrateOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }

                    Picker("Codec", selection: $codec) {
                        Text("H.264 (AVC)").tag("h264")
                        Text("H.265 (HEVC)").tag("h265")
                    }
                    .onChange(of: codec) { _, newValue in
                        // HDR requires HEVC; turn it off if the user drops to H.264.
                        if newValue != "h265" { hdr = false }
                    }

                    Toggle("HDR", isOn: $hdr)
                        .disabled(codec != "h265")
                }

                Section {
                    Text("H.264 is broadly supported; H.265 (HEVC) is better quality at lower bitrate but needs HEVC hardware decode. HDR requires H.265 plus host HDR and an HDR-capable TV (experimental on tvOS).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Stream Settings")
        }
    }
}

#Preview {
    TVSettingsView()
}

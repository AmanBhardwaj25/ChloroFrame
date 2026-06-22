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

    static let defaultResolution = "1920x1080"
    static let defaultFps        = 60
    static let defaultBitrate    = 0   // 0 = auto (computed from resolution/fps)

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

                    Toggle("HDR", isOn: $hdr)
                }

                Section {
                    Text("HDR streams with HEVC and needs the host to have HDR enabled and an HDR-capable TV. It's experimental on tvOS. With HDR off the stream uses H.264.")
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

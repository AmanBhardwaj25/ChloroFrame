//
//  TVStreamOverlays.swift
//  ChloroFrameTV
//
//  In-stream overlays driven by the Siri Remote Menu button:
//   - TVStreamControlsOverlay: the nav/shortcuts menu (Stats toggle, Disconnect).
//   - TVStreamStatsHUD: a compact live stats panel (no tvOS HUD existed before).
//
//  Both appear while focus interaction is re-enabled (see TVStreamSurface.overlayActive), so the
//  remote navigates them normally.
//

import SwiftUI

private func tvCodecName(_ c: VideoCodec) -> String {
    switch c {
    case .h264: return "H.264"
    case .hevc: return "H.265"
    case .av1:  return "AV1"
    }
}

/// Focusable controls menu shown on Menu-button tap.
struct TVStreamControlsOverlay: View {
    let statsOn: Bool
    let onToggleStats: () -> Void
    let onDisconnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                Text("Stream Controls")
                    .font(.system(size: 40, weight: .bold))

                VStack(alignment: .leading, spacing: 8) {
                    shortcut("Touchpad", "Move the pointer")
                    shortcut("Click", "Left click  ·  hold = right click")
                    shortcut("Edge clicks", "Scroll up / down / left / right")
                    shortcut("Play/Pause", "Disconnect")
                    shortcut("Menu", "Open / close this menu")
                }
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

                HStack(spacing: 24) {
                    Button(statsOn ? "Hide Stats" : "Show Stats") { onToggleStats() }
                    Button("Disconnect", role: .destructive) { onDisconnect() }
                    Button("Resume") { onClose() }
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(48)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.black.opacity(0.85)))
            .frame(maxWidth: 1000)
        }
        .onExitCommand { onClose() }   // Menu while the overlay is up closes it
    }

    private func shortcut(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            Text(key).frame(width: 220, alignment: .leading).foregroundStyle(.primary)
            Text(desc)
        }
    }
}

/// Compact live stats panel (top-trailing). Reads the @Observable collector snapshot.
struct TVStreamStatsHUD: View {
    let collector: StreamStatsCollector

    var body: some View {
        let s = collector.current
        VStack(alignment: .leading, spacing: 6) {
            Text("STREAM STATS").font(.system(size: 18, weight: .bold)).foregroundStyle(.green)
            row("Resolution", "\(s.reqWidth) × \(s.reqHeight)")
            row("FPS", String(format: "%.0f / %d", s.measFps, s.reqFps))
            row("Bitrate", String(format: "%.1f Mbps", s.measBitrateMbps))
            row("Codec", tvCodecName(s.recvCodec ?? s.reqCodec) + (s.reqHdr ? " · HDR" : ""))
            row("Decode", String(format: "%.1f ms", s.decodeAvgMs))
            row("Frames", "\(s.framesDecoded) · \(s.framesDropped) dropped")
            row("Loss", String(format: "%.1f%%", s.lossPercent))
            row("Audio", s.audioState)
        }
        .font(.system(size: 18, design: .monospaced))
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(key).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value).foregroundStyle(.white)
        }
    }
}

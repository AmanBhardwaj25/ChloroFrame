//
//  StreamStatsHUD.swift
//  ChloroFrame
//
//  Translucent overlay showing live stream health metrics.
//  Toggle with Ctrl+Option+Command+S during an active stream.

import SwiftUI

struct StreamStatsHUD: View {

    let collector: StreamStatsCollector
    let awdlActive: Bool

    var body: some View {
        let s = collector.current
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.2)).padding(.vertical, 6)
            requestedSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            receivedSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            networkSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            decodeSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            renderSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            audioSection(s)
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            wirelessSection
        }
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            Text("STREAM STATS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Text("^⌥⌘S")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func requestedSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("REQUESTED")
            row("Resolution", "\(s.reqWidth) × \(s.reqHeight)")
            if s.reconActive {
                row("Upscaling", "→ \(s.reconOutW) × \(s.reconOutH)  MetalFX")
            } else if s.reconRequested {
                row("Upscaling", s.reconReason.isEmpty ? "fell back" : "fell back · \(s.reconReason)")
            }
            row("Target",     "\(s.reqFps) fps  ·  \(s.reqBitrateKbps / 1000) Mbps")
            row("Codec",      s.reqCodec.displayName)
            row("HDR",        s.reqHdr ? "requested" : "not requested")
        }
    }

    private func receivedSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("RECEIVED")
            row("FPS",     String(format: "%.1f", s.measFps))
            row("Bitrate", String(format: "%.1f Mbps", s.measBitrateMbps))
            row("Codec",   s.recvCodec?.displayName ?? "—")
            row("HDR",     s.recvHdr.map { $0 ? "received" : "not received" } ?? "—")
        }
    }

    private func networkSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("NETWORK")
            row("Packets",  "\(s.packetsReceived) rx  ·  \(s.packetsRecovered) FEC")
            row("Frames",   "\(s.framesAssembled) ok  ·  \(s.framesLost) lost")
            row("Loss",     String(format: "%.1f%%", s.lossPercent))
            row("Jitter",   String(format: "%.1f ms", s.jitterMs))
        }
    }

    private func decodeSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("DECODE")
            row("Latency", String(format: "avg %.1f ms  max %.1f ms", s.decodeAvgMs, s.decodeMaxMs))
            row("Frames",  "\(s.framesDecoded) decoded  ·  \(s.framesDropped) dropped")
        }
    }

    private func renderSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("RENDER")
            row("Draw interval", String(format: "%.2f ms", s.drawIntervalMs))
            row("Draw p99/max", String(format: "%.2f / %.2f ms", s.drawIntervalP99Ms, s.drawIntervalMaxMs))
            row("Frame age",     String(format: "%.1f ms", s.frameAgeMs))
            row("Repeats",       String(format: "%.1f /s", s.repeatedFramesPerSec))
            row("Overwrites",    String(format: "%.1f /s", s.overwrittenPerSec))
            row("Late drops",    String(format: "%.1f /s", s.lateDroppedPerSec))
            row("Queue depth",   String(format: "%.2f avg  %d peak", s.renderQueueDepth, s.renderQueueHighWatermark))
        }
    }

    private func audioSection(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label("AUDIO")
            row("State",    s.audioState)
            row("Buffered", String(format: "%.0f ms  (tgt %.0f)", s.audioBufferedMs, s.audioTargetMs))
            row("Glitches", "\(s.audioUnderruns) under  ·  \(s.audioOverruns) over")
            row("Drift",    "\(s.audioDriftDrops) drop  ·  \(s.audioDriftInserts) ins")
            row("Lat clamp", String(format: "%.0f ms skipped", s.audioLatencyClampMs))
            row("Loss/reord","\(s.audioLoss) loss  ·  \(s.audioReorder) reord")
            row("Decoded",  "\(s.audioDecoded)")
        }
    }

    private var wirelessSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            label("WIRELESS")
            HStack(spacing: 5) {
                Circle()
                    .fill(awdlActive ? Color.orange : Color.accentColor)
                    .frame(width: 6, height: 6)
                Text(awdlActive ? "AWDL active" : "AWDL suppressed")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Primitives

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, 1)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key)
                .frame(width: 76, alignment: .leading)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

private extension VideoCodec {
    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "H.265"
        case .av1:  return "AV1"
        }
    }
}

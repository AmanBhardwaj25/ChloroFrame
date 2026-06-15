//
//  StreamControlsInfo.swift
//  ChloroFrame
//
//  Single source of truth for the in-stream control shortcuts, plus a reusable list view.
//  Used by the hold-⌃⌥⌘ discovery overlay (in the stream) and the help window (host list).
//  The Ctrl+Option+Command trio is reserved locally and never forwarded to the host, so every
//  shortcut here is safe to press mid-game. See keyboard-remapping.md (§6).
//

import SwiftUI

struct StreamControl: Identifiable {
    let id = UUID()
    let keys: String       // e.g. "⌃⌥⌘ Q"
    let title: String
    let detail: String?
}

enum StreamControlsInfo {
    /// The trio glyphs, shown as the heading of every controls view.
    static let trio = "⌃⌥⌘"

    static let controls: [StreamControl] = [
        StreamControl(keys: "Hold \(trio)", title: "Show this list",
                      detail: "Keep holding the three for a moment while streaming."),
        StreamControl(keys: "\(trio) Q", title: "Disconnect", detail: nil),
        StreamControl(keys: "\(trio) M", title: "Show / hide the Mac cursor", detail: nil),
        StreamControl(keys: "\(trio) S", title: "Toggle the stats overlay", detail: nil),
        StreamControl(keys: "\(trio) F", title: "fn layer for 10 seconds",
                      detail: "Arrows → Page Up/Down, Home, End · Delete → Forward Delete"),
    ]
}

/// Reusable rows. `onLight` picks legible colors for a light window vs. the dark stream overlay.
struct StreamControlsList: View {
    var onLight: Bool = false

    private var keyColor: Color { onLight ? Color(white: 0.20) : .white }
    private var titleColor: Color { onLight ? Color(white: 0.10) : .white }
    private var detailColor: Color { onLight ? Color(white: 0.45) : Color(white: 0.75) }
    private var chipFill: Color { onLight ? Color(white: 0.92) : Color(white: 1.0).opacity(0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(StreamControlsInfo.controls) { c in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(c.keys)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(keyColor)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(chipFill))
                        .frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(titleColor)
                        if let d = c.detail {
                            Text(d)
                                .font(.system(size: 11))
                                .foregroundStyle(detailColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Help window opened from the (?) icon in the host list. Same content as the in-stream overlay.
struct StreamControlsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stream controls").font(.headline)
                Text("The \(StreamControlsInfo.trio) keys are reserved for ChloroFrame and are never sent to the host, so these are always safe to press while streaming.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StreamControlsList(onLight: true)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

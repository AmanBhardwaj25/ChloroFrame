//
//  KeybindEditorView.swift
//  ChloroFrame
//
//  Editor for the four remappable modifier keys (fn / control / option / command).
//  Click a key to "listen", then press the key you want it to become. Changes are staged
//  and only persist on Apply; Cancel discards. See keyboard-remapping.md.
//

import SwiftUI
import AppKit
import Combine

// Captures the next keystroke (a modifier, letter/digit, or F-key) and turns it into a binding
// token while the editor is in "listen" mode. Local monitor, scoped to this app.
@MainActor
final class KeyCaptureController: ObservableObject {
    @Published var listeningFor: String?   // modifier id currently capturing, nil = idle
    private var monitor: Any?
    var onCapture: ((_ modifier: String, _ token: String) -> Void)?

    func start(for modifier: String) {
        stop()
        listeningFor = modifier
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let mod = self.listeningFor else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.stop(); return nil } // Esc cancels
            if let token = Self.token(for: event) {
                self.onCapture?(mod, token)
                self.stop()
                return nil   // consume so it doesn't go anywhere else
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        listeningFor = nil
    }

    private static let fKeyCodes: [Int: Int] =
        [122:1, 120:2, 99:3, 118:4, 96:5, 97:6, 98:7, 100:8, 101:9, 109:10, 103:11, 111:12]

    static func token(for event: NSEvent) -> String? {
        switch event.type {
        case .flagsChanged:
            let f = event.modifierFlags
            switch Int(event.keyCode) {
            case 0x3B, 0x3E: return f.contains(.control)  ? "ctrl"  : nil
            case 0x3A, 0x3D: return f.contains(.option)   ? "alt"   : nil
            case 0x37, 0x36: return f.contains(.command)  ? "win"   : nil
            case 0x38, 0x3C: return f.contains(.shift)    ? "shift" : nil
            case 0x3F:       return f.contains(.function) ? "fn"    : nil
            default:         return nil
            }
        case .keyDown:
            if let n = fKeyCodes[Int(event.keyCode)] { return "f\(n)" }
            if let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let u = chars.uppercased().unicodeScalars.first,
               (65...90).contains(u.value) || (48...57).contains(u.value) {
                return chars.lowercased()
            }
            return nil
        default:
            return nil
        }
    }
}

struct KeybindEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tokens: [String: String] = KeyBindingStore.loadTokens()
    @StateObject private var capture = KeyCaptureController()
    @State private var clearMode = false   // when armed, clicking a card cycles default ↔ blocked

    // Bottom-left modifier row order.
    private let mods: [(id: String, mac: String)] = [
        ("fn", "fn"), ("control", "control"), ("option", "option"), ("command", "command"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Custom Keybinds").font(.headline)
                Text("Only these four modifier keys can be remapped. Click one, then press the key it should become.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                ForEach(mods, id: \.id) { m in keyCard(m.id, mac: m.mac) }
            }

            HStack(spacing: 8) {
                Button("Command → Control") { tokens["command"] = "ctrl" }
                Button("Block Windows key") { tokens["command"] = "block" }
                Button("Reset all") { tokens = [:]; capture.stop(); clearMode = false }
            }
            .buttonStyle(.bordered)
            .font(.caption)

            Button(clearMode ? "Done" : "Remove a binding / set to default") {
                if clearMode { clearMode = false }
                else { capture.stop(); clearMode = true }
            }
            .buttonStyle(.borderedProminent)
            .tint(clearMode ? .red : .blue)
            .font(.caption)

            if clearMode {
                Text("Click a key to cycle: remove its rebind → block it (sends nothing) → default. Then click Done.")
                    .font(.caption2).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                Label("Volume and media keys can't be used on the host PC.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Cancel") { capture.stop(); dismiss() }
                Spacer()
                Button("Apply") {
                    KeyBindingStore.saveTokens(tokens)
                    capture.stop()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { capture.onCapture = { mod, token in tokens[mod] = token } }
        .onDisappear { capture.stop() }
    }

    private func keyCard(_ id: String, mac: String) -> some View {
        let token = tokens[id]
        let listening = capture.listeningFor == id
        let borderColor: Color = clearMode ? .red : (listening ? .accentColor : .gray.opacity(0.4))
        let borderWidth: CGFloat = (clearMode || listening) ? 2 : 1
        return VStack(spacing: 6) {
            Text(mac)                                          // Mac-level label, grey
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.40))
            Text(listening ? "press a key…" : KeyBindingStore.displayLabel(forToken: token))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.70, green: 0.52, blue: 0.0))   // host bind, readable amber-yellow
                .lineLimit(1)
        }
        .frame(width: 116, height: 60)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.70)))   // editable: light grey
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: borderWidth))
        .contentShape(Rectangle())
        .onTapGesture {
            if clearMode { cycleClear(id) } else { capture.start(for: id) }
        }
        .contextMenu {
            Button("Default (no remap)") { tokens[id] = nil }
            Button("Block / None")       { tokens[id] = "block" }
        }
        .help(clearMode ? "Click to cycle Default ↔ Blocked." : "Click to rebind. Right-click for Default / Block.")
    }

    // Clear-mode click: custom rebind -> default, default -> blocked, blocked -> default.
    private func cycleClear(_ id: String) {
        if let t = tokens[id], t.lowercased() != "block" {
            tokens[id] = nil          // remove custom rebind -> default
        } else if tokens[id] == nil {
            tokens[id] = "block"      // default -> blocked (sends nothing)
        } else {
            tokens[id] = nil          // blocked -> default
        }
    }
}

#Preview {
    KeybindEditorView()
}

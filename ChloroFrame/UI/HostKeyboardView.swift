//
//  HostKeyboardView.swift
//  ChloroFrame
//
//  A 2D on-screen keyboard that represents the HOST (Windows) keyboard (see controller-mapping.md
//  §7, option b). The user clicks keys to assemble a host chord for a controller binding; the keys
//  are never sent through the Mac, so macOS cannot intercept them (Win, F-keys, media all act only
//  on the host). Each key carries a token from the KeyToken vocabulary; selection toggles that
//  token in the binding's key list.
//
//  Apollo is Windows-only, so this is a full 104-key layout plus the function/nav/numpad clusters
//  and media keys (volume, transport, print screen, etc.).
//

import SwiftUI

// One key on the virtual keyboard. `token` empty means a spacer (layout gap, not clickable).
struct HostKey: Identifiable {
    let id = UUID()
    let label: String
    let token: String
    var width: CGFloat = 1     // in key-units
    var spacer: Bool { token.isEmpty }
}

enum HostKeyboardLayout {
    private static func k(_ label: String, _ token: String, _ w: CGFloat = 1) -> HostKey {
        HostKey(label: label, token: token, width: w)
    }
    private static func gap(_ w: CGFloat) -> HostKey { HostKey(label: "", token: "", width: w) }

    static let rows: [[HostKey]] = [
        // Media / extras row.
        [k("Vol-", "volumedown", 1.4), k("Vol+", "volumeup", 1.4), k("Mute", "mute", 1.4), gap(0.6),
         k("Play", "playpause", 1.4), k("Stop", "stop", 1.4), k("Prev", "prevtrack", 1.4), k("Next", "nexttrack", 1.4)],

        // Function row.
        [k("Esc", "esc"), gap(0.5),
         k("F1", "f1"), k("F2", "f2"), k("F3", "f3"), k("F4", "f4"), gap(0.4),
         k("F5", "f5"), k("F6", "f6"), k("F7", "f7"), k("F8", "f8"), gap(0.4),
         k("F9", "f9"), k("F10", "f10"), k("F11", "f11"), k("F12", "f12"), gap(0.5),
         k("PrtSc", "printscreen"), k("ScrLk", "scrolllock"), k("Pause", "pause")],

        // Number row + nav top + numpad top.
        [k("`", "grave"), k("1", "1"), k("2", "2"), k("3", "3"), k("4", "4"), k("5", "5"),
         k("6", "6"), k("7", "7"), k("8", "8"), k("9", "9"), k("0", "0"),
         k("-", "minus"), k("=", "equal"), k("Back", "backspace", 2), gap(0.5),
         k("Ins", "insert"), k("Home", "home"), k("PgUp", "pageup"), gap(0.5),
         k("NumLk", "numlock"), k("/", "numdivide"), k("*", "nummultiply"), k("-", "numsubtract")],

        // QWERTY row + nav middle + numpad 7-9, +.
        [k("Tab", "tab", 1.5),
         k("Q", "q"), k("W", "w"), k("E", "e"), k("R", "r"), k("T", "t"), k("Y", "y"),
         k("U", "u"), k("I", "i"), k("O", "o"), k("P", "p"),
         k("[", "lbracket"), k("]", "rbracket"), k("\\", "backslash", 1.5), gap(0.5),
         k("Del", "delete"), k("End", "end"), k("PgDn", "pagedown"), gap(0.5),
         k("7", "num7"), k("8", "num8"), k("9", "num9"), k("+", "numadd")],

        // Home row + numpad 4-6.
        [k("Caps", "capslock", 1.75),
         k("A", "a"), k("S", "s"), k("D", "d"), k("F", "f"), k("G", "g"), k("H", "h"),
         k("J", "j"), k("K", "k"), k("L", "l"),
         k(";", "semicolon"), k("'", "quote"), k("Enter", "enter", 2.25), gap(4.0),
         k("4", "num4"), k("5", "num5"), k("6", "num6")],

        // Shift row + Up + numpad 1-3, Enter.
        [k("Shift", "shift", 2.25),
         k("Z", "z"), k("X", "x"), k("C", "c"), k("V", "v"), k("B", "b"), k("N", "n"), k("M", "m"),
         k(",", "comma"), k(".", "period"), k("/", "slash"), k("Shift", "shift", 2.75), gap(1.5),
         k("Up", "up"), gap(1.5),
         k("1", "num1"), k("2", "num2"), k("3", "num3"), k("Ent", "numenter")],

        // Bottom row + arrows + numpad 0, decimal.
        [k("Ctrl", "ctrl", 1.25), k("Win", "win", 1.25), k("Alt", "alt", 1.25),
         k("Space", "space", 6.25), k("Alt", "alt", 1.25), k("Win", "win", 1.25),
         k("Menu", "apps", 1.25), k("Ctrl", "ctrl", 1.25), gap(0.5),
         k("Left", "left"), k("Down", "down"), k("Right", "right"), gap(0.5),
         k("0", "num0", 2), k(".", "numdecimal")],
    ]
}

struct HostKeyboardView: View {
    let selected: Set<String>
    let onTap: (String) -> Void

    private let unit: CGFloat = 36
    private let gapSize: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: gapSize) {
            ForEach(Array(HostKeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gapSize) {
                    ForEach(row) { key in keyView(key) }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: HostKey) -> some View {
        let w = key.width * unit + (key.width - 1) * gapSize
        if key.spacer {
            Color.clear.frame(width: w, height: unit)
        } else {
            let on = selected.contains(key.token)
            Text(key.label)
                .font(.system(size: 11, weight: on ? .bold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: w, height: unit)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(on ? Color.accentColor : Color.gray.opacity(0.18)))
                .contentShape(Rectangle())
                .onTapGesture { onTap(key.token) }
        }
    }
}

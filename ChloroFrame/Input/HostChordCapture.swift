//
//  HostChordCapture.swift
//  ChloroFrame
//
//  Captures a host keyboard chord by listening for one keystroke on the Mac keyboard and turning
//  the held modifiers plus the main key into a list of host key tokens (e.g. Alt+Tab -> ["alt",
//  "tab"]). Used when authoring a controller binding whose target is a keyboard chord.
//
//  The tokens match the vocabulary in ControllerMappingStore.KeyToken / KeyBindingStore so the
//  translator can resolve them to host virtual-keys later. Local monitor, scoped to this app.
//

import AppKit
import Combine

@MainActor
final class HostChordCapture: ObservableObject {
    @Published private(set) var capturing = false
    @Published private(set) var tokens: [String] = []

    private var monitor: Any?

    func start() {
        stop()
        tokens = []
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }  // Esc cancels (so Esc itself can't be bound)
            if let chord = Self.chord(for: event), !chord.isEmpty {
                self.tokens = chord
                self.stop()
                return nil   // consume so the keystroke goes nowhere else
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        capturing = false
    }

    func clear() { tokens = [] }

    // Modifiers first, then the main key. A bare modifier press yields no main key, so the chord
    // only finalizes on a real key (Tab, a letter, F-key, etc.) held with optional modifiers.
    static func chord(for event: NSEvent) -> [String]? {
        guard let key = mainKey(for: event) else { return nil }
        var mods: [String] = []
        let f = event.modifierFlags
        if f.contains(.control) { mods.append("ctrl") }
        if f.contains(.option)  { mods.append("alt") }
        if f.contains(.shift)   { mods.append("shift") }
        if f.contains(.command) { mods.append("win") }
        return mods + [key]
    }

    private static let fKeyCodes: [Int: Int] =
        [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12]

    private static func mainKey(for event: NSEvent) -> String? {
        let kc = Int(event.keyCode)
        switch kc {
        case 48:        return "tab"
        case 36, 76:    return "enter"
        case 49:        return "space"
        case 51:        return "backspace"
        case 117:       return "delete"
        case 123:       return "left"
        case 124:       return "right"
        case 125:       return "down"
        case 126:       return "up"
        default:
            if let n = fKeyCodes[kc] { return "f\(n)" }
            if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
               let u = chars.unicodeScalars.first,
               (97...122).contains(u.value) || (48...57).contains(u.value) {
                return chars
            }
            return nil
        }
    }
}

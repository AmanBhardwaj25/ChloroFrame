//
//  KeyBindingStore.swift
//  ChloroFrame
//
//  User-configurable remaps for the four editable modifier keys (command, option, control,
//  fn). Only these four are remappable; everything else is fixed. See keyboard-remapping.md.
//
//  A binding maps a modifier to a host target:
//    - unchanged: default behaviour (the macToWin32 mapping)
//    - block:     send nothing to the host (this is how the Windows key gets unbound)
//    - vk(Int):   send this Win32 virtual-key, held with full fidelity (down on press,
//                 up on release; the host handles key-repeat), so the modifier behaves
//                 exactly like the key it was bound to
//
//  Storage: UserDefaults, one global set (host assumed Windows / Apollo). Persisted as a
//  simple [String: String] of modifier -> token so it is easy to inspect and to set for
//  testing before the editor UI exists, e.g.:
//
//      defaults write <app-bundle-id> customKeyBindings -dict \
//          command ctrl  option block  control f13  fn home
//
//  Tokens: unchanged | block/none | ctrl | alt/option | win/command | shift |
//          a single letter a-z | f1..f12

import Foundation

struct KeyBindingStore {

    enum Target: Equatable {
        case unchanged
        case block
        case vk(Int)
    }

    static let editableModifiers = ["command", "option", "control", "fn"]
    private static let defaultsKey = "customKeyBindings"

    // modifier name -> target (only entries that differ from unchanged are stored)
    private var map: [String: Target]

    private init(map: [String: Target]) { self.map = map }

    static func load(_ defaults: UserDefaults = .standard) -> KeyBindingStore {
        var resolved: [String: Target] = [:]
        if let raw = defaults.dictionary(forKey: defaultsKey) as? [String: String] {
            for (mod, token) in raw where editableModifiers.contains(mod) {
                if let t = resolveToken(token), t != .unchanged { resolved[mod] = t }
            }
        }
        return KeyBindingStore(map: resolved)
    }

    func target(for modifier: String) -> Target { map[modifier] ?? .unchanged }

    // ── Editor-facing token API (the editor works in raw token strings) ──────────

    /// Raw persisted tokens (modifier -> token), for the editor to display/edit.
    static func loadTokens(_ defaults: UserDefaults = .standard) -> [String: String] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) as? [String: String] else { return [:] }
        return raw.filter { editableModifiers.contains($0.key) }
    }

    /// Persist tokens; drops empty/unchanged entries, removes the key entirely if nothing custom.
    static func saveTokens(_ tokens: [String: String], _ defaults: UserDefaults = .standard) {
        let cleaned = tokens.filter {
            editableModifiers.contains($0.key) &&
            !$0.value.isEmpty &&
            !["unchanged", "default"].contains($0.value.lowercased())
        }
        if cleaned.isEmpty { defaults.removeObject(forKey: defaultsKey) }
        else { defaults.set(cleaned, forKey: defaultsKey) }
    }

    /// Human-readable label for a token, for the host-binding display.
    static func displayLabel(forToken token: String?) -> String {
        guard let token, !token.isEmpty else { return "default" }
        switch token.lowercased() {
        case "unchanged", "default":           return "default"
        case "block", "none":                  return "blocked"
        case "ctrl", "control":                return "Control"
        case "alt", "option", "opt":           return "Alt"
        case "win", "cmd", "command", "super": return "Win"
        case "shift":                          return "Shift"
        default:                               return token.count <= 3 ? token.uppercased() : token
        }
    }

    /// Resolve a persisted token to a target. nil for an unrecognised token.
    static func resolveToken(_ token: String) -> Target? {
        let s = token.lowercased()
        switch s {
        case "", "unchanged", "default":        return .unchanged
        case "block", "none":                   return .block
        case "ctrl", "control":                 return .vk(0xA2)   // VK_LCONTROL
        case "alt", "option", "opt":            return .vk(0xA4)   // VK_LMENU
        case "win", "cmd", "command", "super":  return .vk(0x5B)   // VK_LWIN
        case "shift":                           return .vk(0xA0)   // VK_LSHIFT
        default:
            // single letter a-z or digit 0-9 -> Win32 VK (uppercase ASCII value)
            if s.count == 1, let u = s.uppercased().unicodeScalars.first,
               (65...90).contains(u.value) || (48...57).contains(u.value) {
                return .vk(Int(u.value))
            }
            // function key f1-f12 -> VK_F1 (0x70) onward
            if s.hasPrefix("f"), let n = Int(s.dropFirst()), (1...12).contains(n) {
                return .vk(0x70 + n - 1)
            }
            return nil
        }
    }
}

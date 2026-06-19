//
//  ControllerMappingStore.swift
//  ChloroFrame
//
//  Persistence for user controller remaps. A binding maps a source (one or more controller
//  elements held together, i.e. a chord) to a target (a host gamepad combo or a host keyboard
//  chord). Brand-agnostic: sources are GameController localizedNames, targets are standard host
//  inputs the host already understands. See controller-mapping.md.
//
//  IMPORTANT: this store is not yet consumed by the stream. It exists so the remapper page is
//  real and testable; applying these bindings to outgoing input is a later step.
//
//  Storage: UserDefaults, a JSON-encoded array under one key.
//

import Foundation

// Standard host gamepad buttons (the host emulates an Xbox-style pad). No "default" case: a
// target is always something concrete; "leave it alone" means simply not creating a binding.
enum GamepadButton: String, CaseIterable, Codable, Identifiable {
    case a, b, x, y
    case leftBumper, rightBumper
    case leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case start, back, guide
    case leftStickButton, rightStickButton

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a:                return "A"
        case .b:                return "B"
        case .x:                return "X"
        case .y:                return "Y"
        case .leftBumper:       return "LB"
        case .rightBumper:      return "RB"
        case .leftTrigger:      return "LT"
        case .rightTrigger:     return "RT"
        case .dpadUp:           return "D-Up"
        case .dpadDown:         return "D-Down"
        case .dpadLeft:         return "D-Left"
        case .dpadRight:        return "D-Right"
        case .start:            return "Start"
        case .back:             return "Back"
        case .guide:            return "Guide"
        case .leftStickButton:  return "L3"
        case .rightStickButton: return "R3"
        }
    }
}

// What a source chord does when held.
enum BindingTarget: Codable, Equatable {
    case gamepad([GamepadButton])   // host gamepad buttons held together
    case keyboard([String])         // host key tokens held together, e.g. ["alt", "tab"]

    var isEmpty: Bool {
        switch self {
        case .gamepad(let b):  return b.isEmpty
        case .keyboard(let k): return k.isEmpty
        }
    }

    var summary: String {
        switch self {
        case .gamepad(let buttons):
            return buttons.map(\.label).joined(separator: " + ")
        case .keyboard(let tokens):
            return tokens.map(KeyToken.label).joined(separator: " + ")
        }
    }
}

// One element of a source chord: either a macOS-known GameController button (by localizedName)
// or a user-labeled learned button (resolved via LearnedButtonStore by device + bit).
enum BindingSource: Codable, Equatable, Hashable {
    case gamepad(name: String)
    case learned(deviceKey: String, bitKey: String, label: String)

    var displayName: String {
        switch self {
        case .gamepad(let name):           return name
        case .learned(_, _, let label):    return label
        }
    }

    var isLearned: Bool { if case .learned = self { return true } else { return false } }
}

// One user binding: a source chord (all elements held) -> a target.
struct ControllerBinding: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sources: [BindingSource]    // known buttons, all held = trigger
    var target: BindingTarget

    var sourceSummary: String { sources.map(\.displayName).joined(separator: " + ") }
}

struct ControllerBindingStore {
    private static let defaultsKey = "controllerBindings"

    static func load(_ defaults: UserDefaults = .standard) -> [ControllerBinding] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([ControllerBinding].self, from: data) else { return [] }
        return list
    }

    static func save(_ bindings: [ControllerBinding], _ defaults: UserDefaults = .standard) {
        if bindings.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

// Display labels for host key tokens. The token vocabulary matches KeyBindingStore (ctrl/alt/
// win/shift, letters, f-keys) plus a few extras a controller chord commonly wants. Resolving a
// token to a host virtual-key for the wire happens in the translator phase.
enum KeyToken {
    static func label(_ token: String) -> String {
        switch token.lowercased() {
        case "ctrl", "control":         return "Ctrl"
        case "alt", "option", "opt":    return "Alt"
        case "win", "cmd", "command":   return "Win"
        case "shift":                   return "Shift"
        case "tab":                     return "Tab"
        case "enter", "return":         return "Enter"
        case "space":                   return "Space"
        case "esc", "escape":           return "Esc"
        case "backspace":               return "Backspace"
        case "delete":                  return "Delete"
        case "up":                      return "Up"
        case "down":                    return "Down"
        case "left":                    return "Left"
        case "right":                   return "Right"
        case "mute":                    return "Mute"
        default:                        return token.count <= 3 ? token.uppercased() : token.capitalized
        }
    }
}

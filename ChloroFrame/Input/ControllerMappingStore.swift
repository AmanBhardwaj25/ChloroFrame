//
//  ControllerMappingStore.swift
//  ChloroFrame
//
//  Persistence for user controller remaps. A binding maps a source (one or more controller
//  elements held together, i.e. a chord) to a target (a host gamepad combo or a host keyboard
//  chord). Brand-agnostic: sources are GameController localizedNames, targets are standard host
//  inputs the host already understands. See controller-mapping.md.
//
//  These models are persisted inside ControllerConfig (per-controller JSON, see
//  ControllerConfigStore) and consumed at runtime by ControllerTranslator to drive the host.
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

// Bindings and learned buttons now persist inside ControllerConfig (per-controller JSON file),
// see ControllerConfigStore.

// Display labels for host key tokens. The token vocabulary matches KeyBindingStore (ctrl/alt/
// win/shift, letters, f-keys) plus a few extras a controller chord commonly wants. Resolving a
// token to a host virtual-key for the wire happens in the translator phase.
enum KeyToken {
    static let modifierOrder = ["ctrl", "alt", "shift", "win"]

    /// Modifiers first (held first when sent), then the rest in their existing order.
    static func ordered(_ tokens: [String]) -> [String] {
        let mods = modifierOrder.filter { tokens.contains($0) }
        let rest = tokens.filter { !modifierOrder.contains($0) }
        return mods + rest
    }

    static func summary(_ tokens: [String]) -> String {
        ordered(tokens).map(label).joined(separator: " + ")
    }

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
        case "capslock":                return "Caps"
        case "insert":                  return "Insert"
        case "home":                    return "Home"
        case "end":                     return "End"
        case "pageup":                  return "PgUp"
        case "pagedown":                return "PgDn"
        case "up":                      return "Up"
        case "down":                    return "Down"
        case "left":                    return "Left"
        case "right":                   return "Right"
        case "mute":                    return "Mute"
        case "volumeup":                return "Vol+"
        case "volumedown":              return "Vol-"
        case "playpause":               return "Play/Pause"
        case "stop":                    return "Stop"
        case "prevtrack":               return "Prev"
        case "nexttrack":               return "Next"
        case "printscreen":             return "PrtScn"
        case "scrolllock":              return "ScrLk"
        case "pause":                   return "Pause"
        case "apps":                    return "Menu"
        case "numlock":                 return "NumLk"
        case "numdivide":               return "Num /"
        case "nummultiply":             return "Num *"
        case "numsubtract":             return "Num -"
        case "numadd":                  return "Num +"
        case "numdecimal":              return "Num ."
        case "numenter":                return "Num Enter"
        case "num0", "num1", "num2", "num3", "num4",
             "num5", "num6", "num7", "num8", "num9":
                                        return "Num " + token.suffix(1)
        case "grave":                   return "`"
        case "minus":                   return "-"
        case "equal":                   return "="
        case "lbracket":                return "["
        case "rbracket":                return "]"
        case "backslash":               return "\\"
        case "semicolon":               return ";"
        case "quote":                   return "'"
        case "comma":                   return ","
        case "period":                  return "."
        case "slash":                   return "/"
        default:                        return token.count <= 3 ? token.uppercased() : token.capitalized
        }
    }
}

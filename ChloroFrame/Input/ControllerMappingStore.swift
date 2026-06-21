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
enum ControllerDisplayStyle: String, Codable, Equatable {
    case xbox
    case playStation
    case generic

    static func inferred(from text: String?) -> ControllerDisplayStyle {
        let lower = (text ?? "").lowercased()
        if lower.contains("dualshock")
            || lower.contains("dualsense")
            || lower.contains("playstation")
            || lower.contains("sony")
            || lower.contains("ds4") {
            return .playStation
        }
        if lower.contains("xbox") { return .xbox }
        return .generic
    }
}

struct GamepadControlDisplay: Equatable {
    let label: String
    let symbolName: String?
}

// GamepadButton's cases + GameController mapping live in GamepadButton.swift (shared with
// tvOS). The display-label layer below is macOS-UI-only, so it stays here as an extension.
extension GamepadButton {
    var label: String {
        display(style: .xbox).label
    }

    func display(style: ControllerDisplayStyle) -> GamepadControlDisplay {
        switch self {
        case .a:
            return GamepadControlDisplay(label: style == .playStation ? "Cross" : "A", symbolName: nil)
        case .b:
            return GamepadControlDisplay(label: style == .playStation ? "Circle" : "B", symbolName: nil)
        case .x:
            return GamepadControlDisplay(label: style == .playStation ? "Square" : "X", symbolName: nil)
        case .y:
            return GamepadControlDisplay(label: style == .playStation ? "Triangle" : "Y", symbolName: nil)
        case .leftBumper:
            return GamepadControlDisplay(label: style == .playStation ? "L1" : "LB", symbolName: nil)
        case .rightBumper:
            return GamepadControlDisplay(label: style == .playStation ? "R1" : "RB", symbolName: nil)
        case .leftTrigger:
            return GamepadControlDisplay(label: style == .playStation ? "L2" : "LT", symbolName: nil)
        case .rightTrigger:
            return GamepadControlDisplay(label: style == .playStation ? "R2" : "RT", symbolName: nil)
        case .dpadUp:
            return GamepadControlDisplay(label: "D-Up", symbolName: nil)
        case .dpadDown:
            return GamepadControlDisplay(label: "D-Down", symbolName: nil)
        case .dpadLeft:
            return GamepadControlDisplay(label: "D-Left", symbolName: nil)
        case .dpadRight:
            return GamepadControlDisplay(label: "D-Right", symbolName: nil)
        case .start:
            return GamepadControlDisplay(label: style == .playStation ? "Options" : "Start", symbolName: nil)
        case .back:
            return GamepadControlDisplay(label: style == .playStation ? "Share" : "Back", symbolName: nil)
        case .guide:
            return GamepadControlDisplay(label: style == .playStation ? "PS" : "Guide", symbolName: nil)
        case .leftStickButton:
            return GamepadControlDisplay(label: "L3", symbolName: nil)
        case .rightStickButton:
            return GamepadControlDisplay(label: "R3", symbolName: nil)
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

// One element of a source chord: either a canonical gamepad control, another macOS-known
// GameController element, or a user-labeled learned button resolved by device + raw-HID bit.
// Sources are resolved by identity, never by the display label shown in the UI.
enum BindingSource: Codable, Equatable, Hashable {
    case gamepad(control: GamepadButton)
    case macos(elementName: String, displayName: String, symbolName: String?)
    case learned(deviceKey: String, bitKey: String, label: String)

    var displayName: String {
        switch self {
        case .gamepad(let control):        return control.label
        case .macos(_, let name, _):       return name
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

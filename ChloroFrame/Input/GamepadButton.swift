//
//  GamepadButton.swift
//  ChloroFrame
//
//  The canonical host gamepad buttons (the host emulates an Xbox-style pad), plus the
//  GameController element mapping. Split out of ControllerMappingStore / ControllerInput
//  so both macOS and tvOS can share it: the wire encoder, the translator base, and the
//  tvOS translator all need this, but the binding/display/HID code does not belong on tvOS.
//
//  The display-label helpers (label / display(style:)) stay macOS-only, as an extension in
//  ControllerMappingStore.swift.
//

import GameController

enum GamepadButton: String, CaseIterable, Codable, Identifiable {
    case a, b, x, y
    case leftBumper, rightBumper
    case leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case start, back, guide
    case leftStickButton, rightStickButton

    var id: String { rawValue }

    /// The GameController button element for this canonical control on a given pad. Shared by the
    /// setup page (which controls are present) and the runtime translator (reading their state),
    /// so a binding's source means the same physical control on both sides.
    func element(in eg: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .a:                return eg.buttonA
        case .b:                return eg.buttonB
        case .x:                return eg.buttonX
        case .y:                return eg.buttonY
        case .leftBumper:       return eg.leftShoulder
        case .rightBumper:      return eg.rightShoulder
        case .leftTrigger:      return eg.leftTrigger
        case .rightTrigger:     return eg.rightTrigger
        case .dpadUp:           return eg.dpad.up
        case .dpadDown:         return eg.dpad.down
        case .dpadLeft:         return eg.dpad.left
        case .dpadRight:        return eg.dpad.right
        case .start:            return eg.buttonMenu
        case .back:             return eg.buttonOptions
        case .guide:            return eg.buttonHome
        case .leftStickButton:  return eg.leftThumbstickButton
        case .rightStickButton: return eg.rightThumbstickButton
        }
    }

    /// Whether this control's host effect is an analog trigger (set the trigger byte) vs a flag.
    var isAnalogTrigger: Bool { self == .leftTrigger || self == .rightTrigger }
}

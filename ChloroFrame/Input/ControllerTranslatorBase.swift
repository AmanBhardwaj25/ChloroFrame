//
//  ControllerTranslatorBase.swift
//  ChloroFrame
//
//  Shared base for the controller -> host bridge. Holds the platform-agnostic pieces both
//  the macOS ControllerTranslator and the tvOS TVControllerTranslator use:
//    - finding the active extended-gamepad controller,
//    - the standard GameController -> HostGamepadState passthrough mapping,
//    - controller-arrival packet (type detection) and multi-controller state sending.
//
//  Platform specifics stay in the subclasses: macOS adds raw-HID paddles, user bindings,
//  keyboard chords, and AppKit focus handling; tvOS is standard passthrough only. No AppKit
//  or UIKit here, so it compiles for both targets.
//

import Foundation
import GameController

@MainActor
class ControllerTranslatorBase {

    let controllerNumber: Int
    weak var transport: StreamTransport?

    init(transport: StreamTransport, controllerNumber: Int = 0) {
        self.transport = transport
        self.controllerNumber = controllerNumber
    }

    /// First connected controller that exposes an extended-gamepad profile. MVP supports one.
    func activeGamepad() -> GCController? {
        GCController.controllers().first { $0.extendedGamepad != nil }
    }

    /// GameController axis (-1...1) -> host signed 16-bit. GameController Y is +1 up, matching the
    /// host's positive-up convention, so no inversion.
    func axis(_ v: Float) -> Int16 { Int16(clamping: Int((v * 32767).rounded())) }

    /// Standard passthrough: every canonical button + analog triggers + sticks, no remaps. This is
    /// the shared baseline; macOS layers bindings on top, tvOS uses it as-is.
    func standardGamepadState(from eg: GCExtendedGamepad) -> HostGamepadState {
        var state = HostGamepadState()
        for control in GamepadButton.allCases where !control.isAnalogTrigger {
            if let button = control.element(in: eg), button.isPressed { state.press(control) }
        }
        state.leftTrigger  = UInt8(clamping: Int(eg.leftTrigger.value  * 255))
        state.rightTrigger = UInt8(clamping: Int(eg.rightTrigger.value * 255))
        state.leftStickX   = axis(eg.leftThumbstick.xAxis.value)
        state.leftStickY   = axis(eg.leftThumbstick.yAxis.value)
        state.rightStickX  = axis(eg.rightThumbstick.xAxis.value)
        state.rightStickY  = axis(eg.rightThumbstick.yAxis.value)
        return state
    }

    /// Sunshine controller type code: 1 = Xbox, 2 = PlayStation, 0 = unknown.
    func arrivalType(for gp: GCController) -> UInt8 {
        if gp.physicalInputProfile is GCDualSenseGamepad || gp.physicalInputProfile is GCDualShockGamepad { return 2 }
        if gp.physicalInputProfile is GCXboxGamepad { return 1 }
        return 0
    }

    func sendArrival(for gp: GCController) {
        let packet = ControllerWire.arrival(controllerNumber: controllerNumber, type: arrivalType(for: gp),
                                            capabilities: 0, supportedButtonFlags: 0x0000_FFFF)
        transport?.sendInput(packet: packet, channel: ControllerWire.channelGamepad(controllerNumber))
    }

    func sendGamepad(_ state: HostGamepadState, mask: UInt16) {
        let packet = ControllerWire.multiController(controllerNumber: controllerNumber,
                                                    activeGamepadMask: mask, state: state)
        transport?.sendInput(packet: packet, channel: ControllerWire.channelGamepad(controllerNumber))
    }
}

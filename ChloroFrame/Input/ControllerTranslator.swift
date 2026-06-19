//
//  ControllerTranslator.swift
//  ChloroFrame
//
//  Runtime controller -> host bridge (controller-mapping.md §5-6, §10). Polls GameController each
//  tick, applies the user's bindings, and drives two host surfaces:
//
//    - Gamepad (level-based): builds a HostGamepadState every tick and sends a MULTI_CONTROLLER
//      packet when it changes. Standard buttons pass through by default; a bound source is
//      consumed and replaced by its target.
//    - Keyboard (edge-based): when a keyboard-target binding becomes active/inactive, sends host
//      key down/up events, ref-counted so combos that share a key never leave it stuck.
//
//  Sources are resolved by identity: macOS-known buttons by GameController name, learned/paddle
//  buttons by their (reportID, byte, bitmask) read live from RawHIDBitReader. Output is paused and
//  released when the app loses focus, matching the keyboard/mouse safety behavior.
//

import Foundation
import GameController
import AppKit

@MainActor
final class ControllerTranslator {

    private weak var transport: StreamTransport?
    private let controllerNumber = 0
    private var bindings: [ControllerBinding]
    private var learnedButtons: [LearnedButton] = []
    private var deviceKey: String?           // hardware id of the controller whose config is loaded
    private let bitReader = RawHIDBitReader()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var lastSentState: HostGamepadState?
    private var arrivalSent = false
    private var paused = false   // app not active: stop driving the host and release held inputs

    // Keyboard edge tracking.
    private var activeKBBindings: Set<UUID> = []
    private var kbTokens: [UUID: [String]] = [:]   // tokens currently held per active kb binding
    private var heldVK: [Int: Int] = [:]           // vk -> refcount across all active kb bindings

    init(transport: StreamTransport) {
        self.transport = transport
        // Load the connected controller's config (bindings + learned/paddle buttons).
        let (key, cfg) = ControllerConfigStore.loadForPrimaryController()
        self.deviceKey = cfg?.hardwareID ?? key
        self.bindings = cfg?.bindings ?? []
        self.learnedButtons = cfg?.learnedButtons ?? []
    }

    /// Reload config for the currently-connected controller (after a hot-plug).
    private func reloadConfig() {
        let (key, cfg) = ControllerConfigStore.loadForPrimaryController()
        deviceKey = cfg?.hardwareID ?? key
        bindings = cfg?.bindings ?? []
        learnedButtons = cfg?.learnedButtons ?? []
    }

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadConfig(); self?.arrivalSent = false; self?.sendArrivalIfNeeded() }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisconnect() }
        })
        // Focus-loss safety: when the app deactivates, release everything and stop driving the
        // host (GameController keeps delivering input even when unfocused, unlike NSEvents).
        observers.append(nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.paused = true; self?.releaseAll() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.paused = false }
        })
        bitReader.start()
        sendArrivalIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        bitReader.stop()
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    /// Release everything so the host sees no stuck inputs (call before transport.stop()).
    func releaseAll() {
        for (vk, count) in heldVK where count > 0 { sendKey(vk: vk, down: false) }
        heldVK.removeAll(); activeKBBindings.removeAll(); kbTokens.removeAll()
        let zero = HostGamepadState()
        sendGamepad(zero, mask: activeGamepad() != nil ? 0x1 : 0x0)
        lastSentState = zero
    }

    // MARK: - Tick

    private func tick() {
        guard !paused else { return }   // app inactive: released already, do not drive the host
        guard let gp = activeGamepad() else {
            if lastSentState != nil { handleDisconnect() }
            return
        }
        let (state, kbActive) = compute(gp)
        if state != lastSentState {
            sendGamepad(state, mask: 0x1)
            lastSentState = state
        }
        applyKeyboard(kbActive)
    }

    private func handleDisconnect() {
        // Release any held keys and tell the host the pad is gone.
        for (vk, count) in heldVK where count > 0 { sendKey(vk: vk, down: false) }
        heldVK.removeAll(); activeKBBindings.removeAll(); kbTokens.removeAll()
        sendGamepad(HostGamepadState(), mask: 0x0)
        lastSentState = nil
        arrivalSent = false
    }

    // MARK: - Compute host state from GameController + bindings

    private func compute(_ gp: GCController) -> (HostGamepadState, [(UUID, [String])]) {
        guard let eg = gp.extendedGamepad else { return (HostGamepadState(), []) }

        // Pressed state of every canonical control present on the pad (shared accessor with setup).
        var gcDown: [GamepadButton: Bool] = [:]
        for c in GamepadButton.allCases {
            if let b = c.element(in: eg) { gcDown[c] = b.isPressed }
        }
        var macosDown: [String: Bool] = [:]
        for element in gp.physicalInputProfile.allElements {
            guard let button = element as? GCControllerButtonInput,
                  let name = ControllerInput.stableName(for: element) else { continue }
            macosDown[name] = button.isPressed
        }
        let learnedByBitKey = Dictionary(learnedButtons.map { ($0.bitKey, $0) }, uniquingKeysWith: { a, _ in a })

        // Resolve a binding source by identity, never by display label: GC controls by canonical
        // id, learned buttons by their (reportID, byte, bitmask) read live from THIS device.
        func held(_ s: BindingSource) -> Bool {
            switch s {
            case .gamepad(let control):
                return gcDown[control] == true
            case .macos(let elementName, _, _):
                return macosDown[elementName] == true
            case .learned(_, let bitKey, _):
                guard let lb = learnedByBitKey[bitKey] else { return false }
                return bitReader.isSet(deviceKey: deviceKey, reportID: lb.reportID, byteIndex: lb.byteIndex, bitmask: lb.bitmask)
            }
        }
        func srcKey(_ s: BindingSource) -> String {
            switch s {
            case .gamepad(let control):      return "gc:\(control.rawValue)"
            case .macos(let name, _, _):     return "macos:\(name)"
            case .learned(_, let bitKey, _): return "ln:\(bitKey)"
            }
        }

        // Active bindings: largest source combo first; an active binding consumes its sources so a
        // combo beats a standalone and consumed controls skip their default passthrough.
        var consumedKeys = Set<String>()
        var consumedControls = Set<GamepadButton>()
        var gamepadPresses: [GamepadButton] = []
        var kbActive: [(UUID, [String])] = []
        for b in bindings.sorted(by: { $0.sources.count > $1.sources.count }) {
            guard b.sources.allSatisfy(held) else { continue }
            guard b.sources.allSatisfy({ !consumedKeys.contains(srcKey($0)) }) else { continue }
            for s in b.sources {
                consumedKeys.insert(srcKey(s))
                if case .gamepad(let control) = s { consumedControls.insert(control) }
            }
            switch b.target {
            case .gamepad(let btns): gamepadPresses.append(contentsOf: btns)
            case .keyboard(let toks): kbActive.append((b.id, toks))
            }
        }

        // Build the state: default passthrough for non-consumed controls, then binding targets.
        var state = HostGamepadState()
        for (control, pressed) in gcDown where pressed && !control.isAnalogTrigger && !consumedControls.contains(control) {
            state.press(control)
        }
        // Triggers pass through their analog value (unless consumed by a binding).
        if !consumedControls.contains(.leftTrigger)  { state.leftTrigger  = UInt8(clamping: Int(eg.leftTrigger.value  * 255)) }
        if !consumedControls.contains(.rightTrigger) { state.rightTrigger = UInt8(clamping: Int(eg.rightTrigger.value * 255)) }
        for btn in gamepadPresses { state.press(btn) }

        // Sticks always pass through (not combo sources). GameController Y is +1 up, matching the
        // host's positive-up convention.
        state.leftStickX  = axis(eg.leftThumbstick.xAxis.value)
        state.leftStickY  = axis(eg.leftThumbstick.yAxis.value)
        state.rightStickX = axis(eg.rightThumbstick.xAxis.value)
        state.rightStickY = axis(eg.rightThumbstick.yAxis.value)

        return (state, kbActive)
    }

    private func axis(_ v: Float) -> Int16 { Int16(clamping: Int((v * 32767).rounded())) }

    // MARK: - Keyboard edges

    private func applyKeyboard(_ active: [(UUID, [String])]) {
        let newIDs = Set(active.map(\.0))
        // Released bindings: key-up their tokens in reverse order.
        for id in activeKBBindings.subtracting(newIDs) {
            for t in (kbTokens[id] ?? []).reversed() { releaseToken(t) }
            kbTokens[id] = nil
        }
        // Newly active bindings: key-down their tokens (modifiers already ordered first).
        for (id, toks) in active where !activeKBBindings.contains(id) {
            kbTokens[id] = toks
            for t in toks { pressToken(t) }
        }
        activeKBBindings = newIDs
    }

    private func pressToken(_ token: String) {
        guard let vk = ControllerWire.winVK(token) else { return }
        let n = (heldVK[vk] ?? 0) + 1
        heldVK[vk] = n
        if n == 1 { sendKey(vk: vk, down: true) }
    }

    private func releaseToken(_ token: String) {
        guard let vk = ControllerWire.winVK(token) else { return }
        let n = (heldVK[vk] ?? 0) - 1
        if n <= 0 { heldVK[vk] = nil; sendKey(vk: vk, down: false) } else { heldVK[vk] = n }
    }

    // MARK: - Send

    private func activeGamepad() -> GCController? {
        GCController.controllers().first { $0.extendedGamepad != nil }
    }

    private func sendArrivalIfNeeded() {
        guard !arrivalSent, let gp = activeGamepad() else { return }
        let type: UInt8
        if gp.physicalInputProfile is GCDualSenseGamepad || gp.physicalInputProfile is GCDualShockGamepad { type = 2 }
        else if gp.physicalInputProfile is GCXboxGamepad { type = 1 }
        else { type = 0 }
        let packet = ControllerWire.arrival(controllerNumber: controllerNumber, type: type,
                                            capabilities: 0, supportedButtonFlags: 0x0000_FFFF)
        transport?.sendInput(packet: packet, channel: ControllerWire.channelGamepad(controllerNumber))
        arrivalSent = true
    }

    private func sendGamepad(_ state: HostGamepadState, mask: UInt16) {
        let packet = ControllerWire.multiController(controllerNumber: controllerNumber,
                                                    activeGamepadMask: mask, state: state)
        transport?.sendInput(packet: packet, channel: ControllerWire.channelGamepad(controllerNumber))
    }

    private func sendKey(vk: Int, down: Bool) {
        transport?.sendInput(packet: ControllerWire.keyboard(vk: vk, modifiers: 0, down: down),
                             channel: ControllerWire.channelKeyboard)
    }
}

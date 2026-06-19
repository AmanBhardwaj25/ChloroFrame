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
//  Phase A handles macOS-known (GameController) sources only. Learned/paddle sources (raw HID at
//  runtime) are layered on in Phase B; bindings that reference a learned source are skipped here.
//

import Foundation
import GameController

@MainActor
final class ControllerTranslator {

    private weak var transport: StreamTransport?
    private let controllerNumber = 0
    private var bindings: [ControllerBinding]
    private var learnedButtons: [LearnedButton] = []
    private let bitReader = RawHIDBitReader()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var lastSentState: HostGamepadState?
    private var arrivalSent = false

    // Keyboard edge tracking.
    private var activeKBBindings: Set<UUID> = []
    private var kbTokens: [UUID: [String]] = [:]   // tokens currently held per active kb binding
    private var heldVK: [Int: Int] = [:]           // vk -> refcount across all active kb bindings

    init(transport: StreamTransport) {
        self.transport = transport
        // Load the connected controller's config (bindings + learned/paddle buttons).
        let (_, cfg) = ControllerConfigStore.loadForPrimaryController()
        self.bindings = cfg?.bindings ?? []
        self.learnedButtons = cfg?.learnedButtons ?? []
    }

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrivalSent = false; self?.sendArrivalIfNeeded() }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisconnect() }
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
        guard let gp = activeGamepad(), let eg = gp.extendedGamepad else {
            if lastSentState != nil { handleDisconnect() }
            return
        }
        let (state, kbActive) = compute(eg)
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

    private struct Contribution {
        let name: String
        let pressed: Bool
        let apply: (inout HostGamepadState) -> Void
    }

    private func compute(_ eg: GCExtendedGamepad) -> (HostGamepadState, [(UUID, [String])]) {
        // Default contributions from the physical pad (digital buttons + analog triggers).
        var items: [Contribution] = []
        func add(_ b: GCControllerButtonInput?, _ apply: @escaping (inout HostGamepadState) -> Void) {
            guard let b, let name = b.localizedName ?? b.unmappedLocalizedName else { return }
            items.append(Contribution(name: name, pressed: b.isPressed, apply: apply))
        }
        add(eg.buttonA) { $0.press(.a) }
        add(eg.buttonB) { $0.press(.b) }
        add(eg.buttonX) { $0.press(.x) }
        add(eg.buttonY) { $0.press(.y) }
        add(eg.leftShoulder) { $0.press(.leftBumper) }
        add(eg.rightShoulder) { $0.press(.rightBumper) }
        add(eg.dpad.up) { $0.press(.dpadUp) }
        add(eg.dpad.down) { $0.press(.dpadDown) }
        add(eg.dpad.left) { $0.press(.dpadLeft) }
        add(eg.dpad.right) { $0.press(.dpadRight) }
        add(eg.buttonMenu) { $0.press(.start) }
        add(eg.buttonOptions) { $0.press(.back) }
        add(eg.buttonHome) { $0.press(.guide) }
        add(eg.leftThumbstickButton) { $0.press(.leftStickButton) }
        add(eg.rightThumbstickButton) { $0.press(.rightStickButton) }
        let lt = eg.leftTrigger, rt = eg.rightTrigger
        items.append(Contribution(name: lt.localizedName ?? "Left Trigger", pressed: lt.isPressed) {
            $0.leftTrigger = UInt8(clamping: Int(lt.value * 255)) })
        items.append(Contribution(name: rt.localizedName ?? "Right Trigger", pressed: rt.isPressed) {
            $0.rightTrigger = UInt8(clamping: Int(rt.value * 255)) })

        var nameDown = Dictionary(items.map { ($0.name, $0.pressed) }, uniquingKeysWith: { $0 || $1 })
        // Learned (paddle) buttons: read their raw-HID bit and key by label so a binding source
        // .learned(...,label) matches via displayName.
        for lb in learnedButtons {
            nameDown[lb.label] = bitReader.isSet(reportID: lb.reportID, byteIndex: lb.byteIndex, bitmask: lb.bitmask)
        }

        // Active bindings: largest source combo first; an active binding consumes its sources so a
        // combo beats a standalone and consumed sources skip their default contribution.
        var consumed = Set<String>()
        var gamepadPresses: [GamepadButton] = []
        var kbActive: [(UUID, [String])] = []
        for b in bindings.sorted(by: { $0.sources.count > $1.sources.count }) {
            let names = b.sources.map(\.displayName)
            guard names.allSatisfy({ nameDown[$0] == true }) else { continue }
            guard names.allSatisfy({ !consumed.contains($0) }) else { continue }
            names.forEach { consumed.insert($0) }
            switch b.target {
            case .gamepad(let btns): gamepadPresses.append(contentsOf: btns)
            case .keyboard(let toks): kbActive.append((b.id, toks))
            }
        }

        // Build the state: default passthrough for non-consumed inputs, then binding targets.
        var state = HostGamepadState()
        for item in items where item.pressed && !consumed.contains(item.name) { item.apply(&state) }
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

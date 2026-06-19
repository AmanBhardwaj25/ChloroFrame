//
//  ControllerInput.swift
//  ChloroFrame
//
//  Brand-agnostic game controller layer built on Apple's GameController.framework. This is the
//  read/observe layer for the controller SETUP page: discovery, live readout, listen/learn
//  capture, and the selected pad's known buttons. It does not send to the host; the runtime
//  bridge that drives the stream is ControllerTranslator (which reads GameController directly).
//
//  Everything goes through GCPhysicalInputProfile, which is the most complete element view of a
//  controller: every button, axis, dpad, trigger that macOS recognises shows up here, each with
//  a localizedName and an Apple-provided SF Symbol (sfSymbolsName). A single valueChangedHandler
//  fires for ANY element that changes, which is exactly what a "listen for the next input"
//  feature needs.
//
//  Note on what you can see: GameController only surfaces elements it recognises for the
//  connected device's profile. Extra/vendor buttons that a controller's firmware folds into a
//  standard input (common in Xbox-emulation mode) are indistinguishable from that standard
//  input, and truly vendor-specific usages may not appear at all. That limit is the whole point
//  of testing with this page.
//

import Foundation
import GameController
import Combine

// Canonical control -> GameController element. The ONE place this mapping lives, shared by the
// setup page (which controls are present) and the runtime translator (reading their state), so a
// binding's source means the same physical control on both sides.
extension GamepadButton {
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

@MainActor
final class ControllerInput: ObservableObject {

    // A snapshot of one connected controller's identity and capabilities, for display.
    struct ControllerInfo: Identifiable {
        let id: ObjectIdentifier
        let displayName: String     // vendorName or a sensible fallback
        let category: String        // productCategory (e.g. "DualShock 4", "Xbox One")
        let profileKind: String     // which GCExtendedGamepad subclass macOS chose
        let hasMotion: Bool         // gyro/accel exposed
        let hasHaptics: Bool        // rumble exposed
        let hasLight: Bool          // lightbar exposed
        let hasBattery: Bool
        let elementCount: Int       // number of distinct elements macOS exposes
    }

    // A single observed input change, for the live readout / capture.
    struct InputEvent: Identifiable {
        let id = UUID()
        let elementName: String     // localizedName, the human label
        let symbolName: String?     // sfSymbolsName, the matching SF Symbol
        let value: Float            // representative analog value 0...1
        let pressed: Bool
        let at: Date
    }

    // Result handed back when "listen" mode captures an input.
    struct CapturedInput {
        let elementName: String     // stable-ish key we persist a mapping under
        let displayName: String     // human label
        let symbolName: String?
    }

    struct KnownControl: Identifiable, Equatable {
        enum Kind: Equatable {
            case canonical(GamepadButton)
            case macos(elementName: String)
        }

        let kind: Kind
        let displayName: String
        let symbolName: String?

        var id: String {
            switch kind {
            case .canonical(let control): return "gc:\(control.rawValue)"
            case .macos(let name): return "macos:\(name)"
            }
        }
    }

    @Published private(set) var controllers: [ControllerInfo] = []
    @Published private(set) var selectedID: ObjectIdentifier?       // controller the live view + listen target
    @Published private(set) var knownControls: [GamepadButton] = [] // canonical controls present on the selected pad
    @Published private(set) var knownSourceControls: [KnownControl] = []
    @Published private(set) var liveValues: [String: Float] = [:]   // element label -> current value
    @Published private(set) var lastEvent: InputEvent?
    @Published private(set) var isListening = false

    var selectedDisplayStyle: ControllerDisplayStyle {
        guard let c = selectedController() else { return .generic }
        if c.physicalInputProfile is GCDualSenseGamepad || c.physicalInputProfile is GCDualShockGamepad {
            return .playStation
        }
        if c.physicalInputProfile is GCXboxGamepad { return .xbox }
        return ControllerDisplayStyle.inferred(from: c.productCategory)
    }

    private var listenCompletion: ((CapturedInput) -> Void)?
    private var comboCompletion: (([CapturedInput]) -> Void)?
    private var comboHeld: Set<String> = []           // elements currently held during combo capture
    private var comboCaptured: [String: CapturedInput] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let c = note.object as? GCController { self?.attach(c) }
                self?.refresh()
            }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Pick up anything already paired, then look for wireless pads.
        for c in GCController.controllers() { attach(c) }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }

    deinit {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        GCController.stopWirelessControllerDiscovery()
    }

    // MARK: - Listen mode

    /// Capture the next single input that crosses the press threshold, then stop.
    func startListening(_ completion: @escaping (CapturedInput) -> Void) {
        stopListening()
        listenCompletion = completion
        isListening = true
    }

    /// Capture a source chord: record every element held together, finalize once they are all
    /// released. Lets the user define a combo source like Home + X by holding both, then letting
    /// go. A single button held and released is just a one-element result.
    func startListeningCombo(_ completion: @escaping ([CapturedInput]) -> Void) {
        stopListening()
        comboCompletion = completion
        comboHeld.removeAll()
        comboCaptured.removeAll()
        isListening = true
    }

    func stopListening() {
        listenCompletion = nil
        comboCompletion = nil
        comboHeld.removeAll()
        comboCaptured.removeAll()
        isListening = false
    }

    func display(for control: GamepadButton) -> GamepadControlDisplay {
        let base = control.display(style: selectedDisplayStyle)
        guard let c = selectedController(),
              let eg = c.extendedGamepad,
              let symbol = control.element(in: eg)?.sfSymbolsName else {
            return base
        }
        return GamepadControlDisplay(label: base.label, symbolName: symbol)
    }

    // MARK: - Selection

    /// Choose which connected controller the live readout and listen mode follow. Switching
    /// clears the readout so stale values from the previous controller do not linger.
    func select(_ id: ObjectIdentifier?) {
        guard id != selectedID else { return }
        selectedID = id
        liveValues.removeAll()
        lastEvent = nil
        stopListening()
        recomputeKnownButtons()
    }

    // The canonical controls present on the selected pad. Uses the same GamepadButton -> element
    // accessor the runtime translator uses, so setup and runtime never drift (a binding's source
    // resolves to the same physical control on both sides).
    private func recomputeKnownButtons() {
        guard let c = selectedController(),
              let eg = c.extendedGamepad else {
            knownControls = []
            knownSourceControls = []
            return
        }
        knownControls = GamepadButton.allCases.filter { $0.element(in: eg) != nil }
        knownSourceControls = Self.sourceControls(for: c, knownControls: knownControls, style: selectedDisplayStyle)
    }

    private func selectedController() -> GCController? {
        guard let id = selectedID else { return nil }
        return GCController.controllers().first(where: { ObjectIdentifier($0) == id })
    }

    private static func sourceControls(for controller: GCController,
                                       knownControls: [GamepadButton],
                                       style: ControllerDisplayStyle) -> [KnownControl] {
        var controls = knownControls.map { control in
            let base = control.display(style: style)
            let symbol = controller.extendedGamepad.flatMap { control.element(in: $0)?.sfSymbolsName }
            return KnownControl(kind: .canonical(control),
                                displayName: base.label,
                                symbolName: symbol ?? base.symbolName)
        }

        let canonicalElementNames = Set(knownControls.compactMap { control -> String? in
            guard let eg = controller.extendedGamepad,
                  let element = control.element(in: eg) else { return nil }
            return stableName(for: element)
        })
        var seenExtraNames = Set<String>()
        let extraButtons = controller.physicalInputProfile.allElements
            .compactMap { element -> KnownControl? in
                guard element is GCControllerButtonInput,
                      let name = stableName(for: element),
                      !canonicalElementNames.contains(name),
                      seenExtraNames.insert(name).inserted else { return nil }
                return KnownControl(kind: .macos(elementName: name),
                                    displayName: name,
                                    symbolName: element.sfSymbolsName)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        controls.append(contentsOf: extraButtons)
        return controls
    }

    static func stableName(for element: GCControllerElement) -> String? {
        element.localizedName ?? element.unmappedLocalizedName
    }

    // MARK: - Wiring

    // GCPhysicalInputProfile has no single catch-all handler, so set one per element. Iterating
    // allElements keeps this brand-agnostic and covers everything macOS exposes for the device
    // (face buttons, triggers, sticks, dpad, and extras like a touchpad button) in one pass.
    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        controller.handlerQueue = .main   // deliver on main so @MainActor access is safe
        for element in controller.physicalInputProfile.allElements {
            if let button = element as? GCControllerButtonInput {
                button.valueChangedHandler = { [weak self] el, _, _ in
                    MainActor.assumeIsolated { self?.handle(el, from: id) }
                }
            } else if let pad = element as? GCControllerDirectionPad {
                pad.valueChangedHandler = { [weak self] el, _, _ in
                    MainActor.assumeIsolated { self?.handle(el, from: id) }
                }
            } else if let axis = element as? GCControllerAxisInput {
                axis.valueChangedHandler = { [weak self] el, _ in
                    MainActor.assumeIsolated { self?.handle(el, from: id) }
                }
            }
        }
    }

    // Only the selected controller drives the live readout and listen capture, so two connected
    // pads do not fight over one shared view (e.g. a DS4 and a GameSir at the same time).
    private func handle(_ element: GCControllerElement, from id: ObjectIdentifier) {
        guard id == selectedID else { return }
        let name = element.localizedName ?? element.unmappedLocalizedName ?? "Unknown"
        let (value, pressed) = Self.reading(of: element)

        // Live readout: keep held inputs visible, drop ones that returned to rest.
        if value > 0.05 { liveValues[name] = value } else { liveValues.removeValue(forKey: name) }
        lastEvent = InputEvent(elementName: name, symbolName: element.sfSymbolsName,
                               value: value, pressed: pressed, at: Date())

        guard isListening else { return }

        // Single capture: fire on a clean press (rising edge past the threshold).
        if let done = listenCompletion {
            if pressed {
                stopListening()
                done(CapturedInput(elementName: name, displayName: name, symbolName: element.sfSymbolsName))
            }
            return
        }

        // Combo capture: accumulate elements while held, finalize when all are released.
        if comboCompletion != nil {
            if pressed {
                comboHeld.insert(name)
                comboCaptured[name] = CapturedInput(elementName: name, displayName: name,
                                                    symbolName: element.sfSymbolsName)
            } else {
                comboHeld.remove(name)
                if comboHeld.isEmpty, !comboCaptured.isEmpty, let done = comboCompletion {
                    let result = Array(comboCaptured.values)
                    stopListening()
                    done(result)
                }
            }
        }
    }

    // Reduce any element kind to a single 0...1 magnitude and a pressed flag.
    private static func reading(of element: GCControllerElement) -> (Float, Bool) {
        if let b = element as? GCControllerButtonInput {
            return (b.value, b.isPressed)
        }
        if let pad = element as? GCControllerDirectionPad {
            let mag = max(abs(pad.xAxis.value), abs(pad.yAxis.value))
            return (mag, mag > 0.5)
        }
        if let axis = element as? GCControllerAxisInput {
            return (abs(axis.value), abs(axis.value) > 0.5)
        }
        return (0, false)
    }

    private func refresh() {
        controllers = GCController.controllers().map { c in
            ControllerInfo(
                id: ObjectIdentifier(c),
                displayName: c.vendorName ?? "Controller",
                category: c.productCategory,
                profileKind: Self.profileKind(of: c),
                hasMotion: c.motion != nil,
                hasHaptics: c.haptics != nil,
                hasLight: c.light != nil,
                hasBattery: c.battery != nil,
                elementCount: c.physicalInputProfile.allElements.count
            )
        }
        // Keep a valid selection: default to the first controller, and clear it if the selected
        // controller went away.
        if controllers.isEmpty {
            liveValues.removeAll(); lastEvent = nil; selectedID = nil
        } else if selectedID == nil || !controllers.contains(where: { $0.id == selectedID }) {
            select(controllers.first?.id)
        }
        recomputeKnownButtons()
    }

    private static func profileKind(of c: GCController) -> String {
        if c.physicalInputProfile is GCDualSenseGamepad { return "DualSense" }
        if c.physicalInputProfile is GCDualShockGamepad { return "DualShock 4" }
        if c.physicalInputProfile is GCXboxGamepad      { return "Xbox" }
        if c.extendedGamepad != nil                     { return "Extended Gamepad" }
        if c.microGamepad != nil                        { return "Micro Gamepad" }
        return "Unknown"
    }
}

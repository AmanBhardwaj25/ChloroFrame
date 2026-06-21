//
//  TVControllerTranslator.swift
//  ChloroFrameTV
//
//  tvOS controller -> host bridge (Phases 7-8). GameController-only, standard passthrough: no raw
//  HID, no learned paddles, no remaps, no keyboard chords. The mapping/sending lives in
//  ControllerTranslatorBase; this adds the tvOS lifecycle (connect/disconnect, poll loop).
//
//  Two input sources, in priority order:
//    1. A physical extended gamepad (Xbox/PlayStation/MFi) — full standard passthrough.
//    2. The Siri Remote as a minimal gamepad (micro gamepad: dpad + select + play/pause), used
//       ONLY when no physical pad is connected, so the remote never fights a real controller.
//  Menu/Back is never sent to the host; it stays local (the stream view's onExitCommand stops
//  the session).
//
//  One controller for MVP. Polls at 120 Hz; sends a MULTI_CONTROLLER packet only on change.
//

import Foundation
import GameController

@MainActor
final class TVControllerTranslator: ControllerTranslatorBase {

    /// When true, the Siri Remote drives the host as a minimal gamepad if no physical pad is
    /// connected. A physical controller always takes the slot.
    var remoteAsGamepad = true

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSentState: HostGamepadState?
    private var arrivalSent = false

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrivalSent = false; self?.tick() }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisconnect() }
        })
        GCController.startWirelessControllerDiscovery {}
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    /// Zero the host pad so nothing is left stuck (call before transport.stop()).
    func releaseAll() {
        let mask: UInt16 = activeController() != nil ? 0x1 : 0x0
        sendGamepad(HostGamepadState(), mask: mask)
        lastSentState = HostGamepadState()
    }

    // MARK: - Private

    private func tick() {
        guard let controller = activeController() else {
            if lastSentState != nil { handleDisconnect() }
            return
        }
        sendArrivalIfNeeded(for: controller)

        let state: HostGamepadState
        if let eg = controller.extendedGamepad {
            state = standardGamepadState(from: eg)
        } else if let mg = controller.microGamepad {
            state = remoteGamepadState(from: mg)
        } else {
            return
        }

        if state != lastSentState {
            sendGamepad(state, mask: 0x1)
            lastSentState = state
        }
    }

    /// Physical extended gamepad wins; otherwise the Siri Remote (micro gamepad) if allowed.
    private func activeController() -> GCController? {
        if let ext = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { return ext }
        if remoteAsGamepad {
            return GCController.controllers().first(where: { $0.microGamepad != nil })
        }
        return nil
    }

    /// Minimal Siri Remote mapping: directional clicks -> host dpad, click/select -> A,
    /// play/pause -> Start. Menu/Back is intentionally not mapped (stays local for stop).
    private func remoteGamepadState(from mg: GCMicroGamepad) -> HostGamepadState {
        var state = HostGamepadState()
        if mg.dpad.up.isPressed    { state.press(.dpadUp) }
        if mg.dpad.down.isPressed  { state.press(.dpadDown) }
        if mg.dpad.left.isPressed  { state.press(.dpadLeft) }
        if mg.dpad.right.isPressed { state.press(.dpadRight) }
        if mg.buttonA.isPressed    { state.press(.a) }
        if mg.buttonX.isPressed    { state.press(.start) }
        return state
    }

    private func handleDisconnect() {
        sendGamepad(HostGamepadState(), mask: 0x0)
        lastSentState = nil
        arrivalSent = false
    }

    private func sendArrivalIfNeeded(for controller: GCController) {
        guard !arrivalSent else { return }
        sendArrival(for: controller)
        arrivalSent = true
    }
}

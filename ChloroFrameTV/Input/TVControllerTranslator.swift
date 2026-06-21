//
//  TVControllerTranslator.swift
//  ChloroFrameTV
//
//  tvOS controller -> host bridge (Phase 7). GameController-only, standard passthrough: no raw
//  HID, no learned paddles, no remaps, no keyboard chords. All the actual mapping/sending lives
//  in ControllerTranslatorBase; this adds the tvOS lifecycle (connect/disconnect, poll loop) and
//  nothing AppKit.
//
//  One controller for MVP. Polls at 120 Hz to match macOS and minimise divergence; sends a
//  MULTI_CONTROLLER packet only when the state changes.
//

import Foundation
import GameController

@MainActor
final class TVControllerTranslator: ControllerTranslatorBase {

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSentState: HostGamepadState?
    private var arrivalSent = false

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrivalSent = false; self?.sendArrivalIfNeeded() }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisconnect() }
        })
        GCController.startWirelessControllerDiscovery {}
        sendArrivalIfNeeded()
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
        let mask: UInt16 = activeGamepad() != nil ? 0x1 : 0x0
        sendGamepad(HostGamepadState(), mask: mask)
        lastSentState = HostGamepadState()
    }

    // MARK: - Private

    private func tick() {
        guard let gp = activeGamepad(), let eg = gp.extendedGamepad else {
            if lastSentState != nil { handleDisconnect() }
            return
        }
        let state = standardGamepadState(from: eg)
        if state != lastSentState {
            sendGamepad(state, mask: 0x1)
            lastSentState = state
        }
    }

    private func handleDisconnect() {
        sendGamepad(HostGamepadState(), mask: 0x0)
        lastSentState = nil
        arrivalSent = false
    }

    private func sendArrivalIfNeeded() {
        guard !arrivalSent, let gp = activeGamepad() else { return }
        sendArrival(for: gp)
        arrivalSent = true
    }
}

//
//  StreamActivityGuard.swift
//  ChloroFrame
//
//  Keeps the display from dimming/sleeping while a stream is active. Input during a session
//  arrives over the network (or from a controller paired to the host), not from local HID/touch,
//  so the OS would otherwise see the client as idle mid-session and blank the screen.
//
//  macOS and tvOS have no shared API for this: macOS holds an IOPM display-sleep assertion via
//  ProcessInfo; tvOS/iOS gate the screensaver/auto-lock through UIApplication's idle timer. This
//  type isolates that split behind one start()/stop() so StreamTransport stays platform-agnostic,
//  matching the AWDLSuppressor split for the other macOS-only piece of start().
//

import Foundation
#if os(tvOS) || os(iOS)
import UIKit
#endif

enum StreamActivityGuard {

    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #endif

    static func start() {
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated, .idleDisplaySleepDisabled],
            reason: "Active stream"
        )
        #elseif os(tvOS) || os(iOS)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #endif
    }

    static func stop() {
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        #elseif os(tvOS) || os(iOS)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        #endif
    }
}

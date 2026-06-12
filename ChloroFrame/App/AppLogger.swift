//
//  AppLogger.swift
//  ChloroFrame
//
//  File I/O logging removed — synchronous writes caused microstutter during video streaming.
//  All methods are intentional no-ops. Diagnostics are now surfaced via the in-stream stats HUD.

import Foundation

final class AppLogger {

    static let shared = AppLogger()
    private init() {}

    func newSession(host: String) {}
    func log(_ message: String, _ component: String, _ step: String) {}
    func logBlock(_ header: String, body: String, _ component: String, _ step: String) {}
}

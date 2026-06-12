//
//  StreamLog.swift
//  ChloroFrame
//
//  Gated diagnostic logging for the streaming hot path.
//
//  All streaming-pipeline console output funnels through here so a normal run
//  performs ZERO log I/O and builds ZERO log strings (the @autoclosure defers
//  string interpolation until after the verbose check). When enabled, lines
//  print from a dedicated utility queue — stdout can block on the console pipe
//  with a debugger attached, and several call sites run on latency-critical
//  threads (receive, decode, render, main).
//
//  Enable with:
//      defaults write fullstacksandbox.com.ChloroFrame verboseStreamLogs -bool YES
//  then relaunch. Disable with -bool NO or `defaults delete`.

import Foundation

enum StreamLog {

    /// Read once at first use; relaunch to change.
    static let verbose = UserDefaults.standard.bool(forKey: "verboseStreamLogs")

    private static let queue = DispatchQueue(label: "chloroframe.streamlog", qos: .utility)

    @inline(__always)
    static func log(_ line: @autoclosure () -> String) {
        guard verbose else { return }
        let s = line()
        queue.async { print(s) }
    }
}

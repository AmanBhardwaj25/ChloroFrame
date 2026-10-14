//
//  DebugFileLog.swift
//  ChloroFrame
//
//  DEBUG builds only: appends diagnostics to /tmp/chloroframe-debug.log so they can be read
//  without Xcode's console. Every entry point takes an @autoclosure and its whole body is
//  inside `#if DEBUG`, so a Release build neither builds the string nor contains the log path
//  (scripts/create_dmg.sh checks the shipped binary for it).
//
//  `write` is synchronous and for one-off lines (negotiation, audit, a handful per connect).
//  `writeAsync` hops to a utility queue and is the one to use from timers or anything that
//  repeats, so file I/O can never stall the caller.
//
//  This is the ONLY sanctioned diagnostic sink. Unqualified `print` is a module-wide no-op
//  (Logging.swift) and StreamLog / AppLogger / SessionLog are no-ops. Do not add `Swift.print`,
//  NSLog or os.Logger calls, and keep any new logging behind DebugFileLog.
//

import Foundation

nonisolated enum DebugFileLog {
    #if DEBUG
    static let path = "/tmp/chloroframe-debug.log"
    private static let queue = DispatchQueue(label: "chloroframe.debug-log", qos: .utility)

    private static func append(_ line: String) {
        let text = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #endif

    /// Synchronous. Release: does nothing and never evaluates `line`.
    static func write(_ line: @autoclosure () -> String) {
        #if DEBUG
        let s = line()
        Swift.print(s)
        append(s)
        #endif
    }

    /// Off-thread. Release: does nothing and never evaluates `line`.
    static func writeAsync(_ line: @autoclosure () -> String) {
        #if DEBUG
        let s = line()
        queue.async { append(s) }
        #endif
    }
}

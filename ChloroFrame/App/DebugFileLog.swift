//
//  DebugFileLog.swift
//  ChloroFrame
//
//  DEBUG builds only: appends one-off negotiation diagnostics to /tmp/chloroframe-debug.log
//  so they can be read without Xcode's console. Called a handful of times per connect, never
//  from the video path. Compiles to nothing in Release.
//

import Foundation

nonisolated enum DebugFileLog {
    static let path = "/tmp/chloroframe-debug.log"

    static func write(_ line: String) {
        #if DEBUG
        Swift.print(line)
        let text = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

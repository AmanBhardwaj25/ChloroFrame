//
//  ProbeLog.swift
//  ChloroFrame
//
//  Tiny diagnostic file logger for the controller probe ONLY. The app's general logging is
//  no-op'd to avoid streaming stutter (see Logging.swift), but the controller test page runs in
//  Settings, off the stream hot path, so writing a few lines per button press is harmless.
//
//  Writes to the repo's logs/session.log, resolved from this source file's location so it works
//  without hardcoding a machine path. Diagnostic/temporary: remove once paddle detection is
//  settled.
//

import Foundation

final class ProbeLog {
    static let shared = ProbeLog()

    private let queue = DispatchQueue(label: "com.chloroframe.probelog")
    private let url: URL
    private var handle: FileHandle?

    private init() {
        // .../ChloroFrame/Input/ProbeLog.swift -> up 3 to repo root -> logs/session.log
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Input
            .deletingLastPathComponent()   // ChloroFrame
            .deletingLastPathComponent()   // repo root
        url = root.appendingPathComponent("logs/session.log")
    }

    func log(_ line: String) {
        queue.async { [self] in
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("[\(stamp)] \(line)\n".utf8)
            if handle == nil {
                let fm = FileManager.default
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            handle?.write(data)
            try? handle?.synchronize()
        }
    }
}

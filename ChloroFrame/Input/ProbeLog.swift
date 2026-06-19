//
//  ProbeLog.swift
//  ChloroFrame
//
//  Tiny diagnostic file logger for the controller probe ONLY. The app's general logging is
//  no-op'd to avoid streaming stutter (see Logging.swift), but the controller test page runs in
//  Settings, off the stream hot path, so writing a few lines per button press is harmless.
//
//  Writes to a real user log location (~/Library/Application Support/ChloroFrame/Logs/session.log)
//  so it works in a distributed build, not just the developer checkout. One shared FileHandle and
//  one shared formatter; no per-line fsync.
//

import Foundation

final class ProbeLog {
    static let shared = ProbeLog()

    private let queue = DispatchQueue(label: "com.chloroframe.probelog")
    private let url: URL
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); return f
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent("ChloroFrame/Logs/session.log")
    }

    /// Where logs are written, for surfacing in the UI.
    var path: String { url.path }

    func log(_ line: String) {
        queue.async { [self] in
            let data = Data("[\(formatter.string(from: Date()))] \(line)\n".utf8)
            if handle == nil {
                let fm = FileManager.default
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            handle?.write(data)
        }
    }
}

//
//  SessionLog.swift
//  ChloroFrame
//
//  Async, non-blocking session diagnostics sink.
//
//  Writes one stats line per second to logs/session.log so a streaming run can be
//  reviewed after the fact. ALL file I/O happens on a dedicated utility queue, never on
//  the receive / decode / render / audio threads, so it cannot stall frame delivery —
//  this is the distinction from the old synchronous AppLogger, whose on-thread writes
//  caused microstutter. Callers only pay a cheap queue.async enqueue.
//
//  This is intentionally separate from StreamLog: StreamLog's verbose firehose logs
//  per-packet / per-frame lines (~2,500/s) and is gated off by default. Routing session
//  stats through it would force the firehose on and reintroduce the stutter. SessionLog
//  is low-frequency (1 Hz) and always on while a stream is active.

import Foundation
import os

final class SessionLog {

    static let shared = SessionLog()

    private let queue  = DispatchQueue(label: "chloroframe.sessionlog", qos: .utility)
    private let url:    URL
    private var handle: FileHandle?
    private var startInstant: Date = .now

    private init() {
        // Resolve <projectRoot>/logs/session.log from this source file's location, so the
        // log lands in the repo on whatever machine built it. Dev diagnostic only; the
        // app is not sandboxed, so writing into the project tree is permitted.
        //   #filePath = <projectRoot>/ChloroFrame/App/SessionLog.swift
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // ChloroFrame
            .deletingLastPathComponent()   // <projectRoot>
        url = projectRoot.appendingPathComponent("logs/session.log")
    }

    /// Resolved absolute path of the session log (for surfacing to the user).
    var path: String { url.path }

    /// Truncate any previous log, write the header, and open the file for appending.
    /// Call once when a stream starts.
    func begin(header: String) {
        queue.async { [self] in
            startInstant = .now
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            writeNow(header)
            Logger(subsystem: "com.chloroframe", category: "session")
                .info("session log → \(self.url.path, privacy: .public)")
        }
    }

    /// Append one line (newline added, prefixed with elapsed session time). Safe from any
    /// thread — the string is captured and the write deferred to the utility queue.
    /// Intended for low-frequency callers (1 Hz stats); not for hot-path use.
    func line(_ s: String) {
        let t = Date.now.timeIntervalSince(startInstant)
        queue.async { [self] in writeNow(String(format: "[t+%6.1fs] ", t) + s) }
    }

    /// Flush and close. Call when the stream stops.
    func end() {
        queue.async { [self] in
            writeNow("[session ended]")
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - queue-confined

    private func writeNow(_ s: String) {
        guard let handle, let data = (s + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}

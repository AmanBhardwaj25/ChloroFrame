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

/// Disk session log, intentionally no-op'd. Even the old async/off-thread file
/// writes are gone — the API is kept so call sites compile unchanged, but no I/O
/// happens. (See Logging.swift.)
final class SessionLog {

    static let shared = SessionLog()
    private init() {}

    var path: String { "" }
    func begin(header: String) {}
    func line(_ s: String) {}
    func end() {}
}

//
//  Logging.swift
//  ChloroFrame
//
//  All diagnostic logging is intentionally no-op'd.
//
//  Synchronous stdout (print) can block on the console pipe with a debugger
//  attached, os.Logger and file writes add per-call overhead, and several log
//  sites sit on latency-critical threads (receive / decode / render / audio).
//  Collectively they caused the microstutter we kept chasing, so every sink is
//  neutralised:
//
//    • print(...)        → shadowed by the no-op below (module-wide)
//    • os.Logger alog/rlog → replaced with NoopLog
//    • StreamLog / SessionLog / AppLogger → no-op bodies
//
//  If you genuinely need a line out (e.g. a one-shot post-stream diagnostic that
//  never runs on the hot path), call `Swift.print(...)` explicitly to bypass the
//  shadow.
//

import Foundation

// MARK: - Module-wide no-op `print`

// A top-level `print` shadows `Swift.print` for all unqualified calls in this
// module, so existing print(...) sites compile unchanged and emit nothing.
@inline(__always)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}

// MARK: - No-op stand-in for os.Logger

// Drop-in for the handful of `Logger` instances (alog/rlog). The @autoclosure
// means the interpolated string is never even built.
struct NoopLog {
    @inline(__always) func info(_ message: @autoclosure () -> String)    {}
    @inline(__always) func notice(_ message: @autoclosure () -> String)  {}
    @inline(__always) func debug(_ message: @autoclosure () -> String)   {}
    @inline(__always) func warning(_ message: @autoclosure () -> String) {}
    @inline(__always) func error(_ message: @autoclosure () -> String)   {}
}

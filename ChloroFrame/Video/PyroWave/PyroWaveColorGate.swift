//
//  PyroWaveColorGate.swift
//  ChloroFrame
//
//  A 10-bit PyroWave stream cannot tell from its bitstream whether the picture is PQ HDR or
//  10-bit SDR; the host's HDR mode message (0x010e) says so, and it can trail the first frames
//  by up to about 150 ms (the host raises it after the first encode and sends it from its
//  control loop). Showing those frames with the PQ assumption flashes an SDR picture bright and
//  turns EDR on and straight off again (review R1, design/pyrowave-review-2026-10-14.md).
//
//  The gate holds back decoded frames until the message has arrived and a frame carries the
//  color it chose, or until `timeout` after the first decoded frame, after which frames pass
//  with the decoder's assumption (an older host that never sends the message keeps the old
//  behavior). Once open it stays open, so a later mid-stream flip shows at most the one frame
//  that was already decoding. Dropping is safe because every PyroWave frame is intra only.
//

import Foundation

nonisolated final class PyroWaveColorGate: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Double
    private var isOpen: Bool
    private var hostColor: PlanarColorParams?
    private var firstFrameAt: Double?
    private var held = 0

    /// Frames held back so far (diagnostics).
    var heldFrames: Int { lock.withLock { held } }

    /// `waitForHost` false (an 8-bit stream, which has no HDR) opens the gate from the start.
    init(waitForHost: Bool, timeout: Double = 0.25) {
        self.isOpen = !waitForHost
        self.timeout = timeout
    }

    /// The color the host's HDR mode message selected.
    func hostReported(_ color: PlanarColorParams) {
        lock.withLock { hostColor = color }
    }

    /// Whether a decoded frame stamped with `frameColor` may be shown. `now` is in seconds on
    /// any monotonic clock.
    func allows(_ frameColor: PlanarColorParams, now: Double) -> Bool {
        lock.withLock {
            if isOpen { return true }
            let first = firstFrameAt ?? now
            firstFrameAt = first
            if let hostColor, frameColor == hostColor { isOpen = true; return true }
            if now - first >= timeout { isOpen = true; return true }
            held += 1
            return false
        }
    }
}

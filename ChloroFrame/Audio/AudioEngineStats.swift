//
//  AudioEngineStats.swift
//  ChloroFrame
//
//  Plain audio-engine value types (state + stats snapshot), split out of
//  AudioEngine.swift so they can be shared with targets that do not link the
//  audio decode path. The macOS target builds the full AudioEngine; the tvOS
//  target needs only these types (referenced by StreamStatsCollector) until the
//  audio path lands in a later phase. Framework-free on purpose.
//

import Foundation

enum AudioEngineState {
    case stopped, priming, running

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .priming: return "priming"
        case .running: return "running"
        }
    }
}

struct AudioEngineStats {
    let state:        AudioEngineState
    let bufferedMs:   Double
    let underrunCount: Int
    let overrunCount: Int
    let decodeCount:  Int
    let driftDrops:   Int    // packets skipped by the drift servo (buffer too full)
    let driftInserts: Int    // packets duplicated by the drift servo (buffer too empty)
    let latencyClampMs: Double  // cumulative ms of oldest audio skipped by the max-latency clamp
    let targetMs:     Double    // current adaptive-jitter-buffer target latency
}

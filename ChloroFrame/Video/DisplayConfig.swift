//
//  DisplayConfig.swift
//  ChloroFrame
//
//  Shared display model and bitrate logic. Kept framework-free so it can be a
//  member of both the macOS and tvOS targets. Platform-specific detection lives
//  in DisplayConfig+macOS.swift (NSScreen / CGDisplay enumeration) and
//  DisplayConfig+tvOS.swift (fixed presets, per design/tvos-port-plan.md 4.1).
//

import Foundation

// A display mode entry as reported by CGDisplayCopyAllDisplayModes (macOS).
// width/height are logical pixels (what macOS System Settings shows as "looks like W×H").
struct DisplayResolution: Identifiable, Hashable {
    let width: Int
    let height: Int
    let refreshRates: [Int]   // available fps for this resolution, sorted ascending

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
}

struct DisplayConfig {
    let width:  Int
    let height: Int
    let fps:    Int
    let hdr:    Bool
    private let _bitrateOverride: Int   // 0 = use computed bitrate

    init(width: Int, height: Int, fps: Int, hdr: Bool, bitrateOverride: Int = 0) {
        self.width  = width
        self.height = height
        self.fps    = fps
        self.hdr    = hdr
        self._bitrateOverride = bitrateOverride
    }

    var bitrate: Int {
        if _bitrateOverride > 0 { return _bitrateOverride }
        let pixels = width * height
        let raw    = 10_000.0 * Double(pixels) / Double(1920 * 1080) * Double(fps) / 60.0
        return max(5_000, min(80_000, Int(raw.rounded())))
    }
}

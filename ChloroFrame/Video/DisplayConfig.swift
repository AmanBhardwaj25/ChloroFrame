//
//  DisplayConfig.swift
//  ChloroFrame
//

import AppKit
import CoreGraphics

// A display mode entry as reported by CGDisplayCopyAllDisplayModes.
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

    // MARK: - Detection

    @MainActor
    static func detect() -> DisplayConfig {
        let screen = NSApp.keyWindow?.screen
                  ?? NSApp.mainWindow?.screen
                  ?? NSScreen.main
                  ?? NSScreen.screens.first!

        // NSScreen.frame is in logical points. A 4K/5K display at 2× HiDPI reports
        // 1920×1080 here — that's the resolution Sunshine should encode at.
        let w = Int(screen.frame.width)  & ~1  // align to even (H.264/HEVC requirement)
        let h = Int(screen.frame.height) & ~1

        let fps = min(screen.maximumFramesPerSecond, 120)
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        return DisplayConfig(width: w, height: h, fps: fps, hdr: hdr)
    }

    /// Physical pixel resolution of the active display (logical points × backing scale),
    /// even-aligned. This is what the renderer's drawable upscales to, so it's the "100%"
    /// reference for the upscaling percentage: source = percent% of this.
    @MainActor
    static func physicalPixelSize() -> (width: Int, height: Int) {
        let screen = NSApp.keyWindow?.screen
                  ?? NSApp.mainWindow?.screen
                  ?? NSScreen.main
                  ?? NSScreen.screens.first!
        let scale = screen.backingScaleFactor
        let w = Int((screen.frame.width  * scale).rounded()) & ~1
        let h = Int((screen.frame.height * scale).rounded()) & ~1
        return (w, h)
    }

    // MARK: - Available display modes

    /// Returns the display modes available on the screen containing the focused window.
    /// Matches what macOS System Settings > Displays shows for that screen.
    @MainActor
    static func availableResolutions() -> [DisplayResolution] {
        let screen = NSApp.keyWindow?.screen
                  ?? NSApp.mainWindow?.screen
                  ?? NSScreen.main
                  ?? NSScreen.screens.first!

        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        guard let cfArray = CGDisplayCopyAllDisplayModes(displayID, nil) else { return [] }

        // CFArray contains CGDisplayModeRef (a CF type). Swift's `as? [CGDisplayMode]` returns
        // nil for CF-only types, so we extract via Unmanaged instead.
        let modes: [CGDisplayMode] = (0..<CFArrayGetCount(cfArray)).compactMap { idx in
            guard let ptr = CFArrayGetValueAtIndex(cfArray, idx) else { return nil }
            return Unmanaged<CGDisplayMode>.fromOpaque(ptr).takeUnretainedValue()
        }

        // Group by logical (width × height); collect all refresh rates per group.
        var map: [String: (Int, Int, Set<Int>)] = [:]
        for mode in modes {
            guard mode.isUsableForDesktopGUI() else { continue }
            let w   = mode.width
            let h   = mode.height
            let fps = Int(mode.refreshRate.rounded())
            guard w > 0, h > 0, fps > 0 else { continue }
            let key = "\(w)x\(h)"
            if var entry = map[key] {
                entry.2.insert(fps)
                map[key] = entry
            } else {
                map[key] = (w, h, [fps])
            }
        }

        return map.values
            .map { w, h, rates in DisplayResolution(width: w, height: h, refreshRates: rates.sorted()) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }
}

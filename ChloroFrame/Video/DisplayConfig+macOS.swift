//
//  DisplayConfig+macOS.swift
//  ChloroFrame
//
//  macOS-only display detection, split out of DisplayConfig.swift so the shared
//  model stays framework-free. Guarded so it compiles to nothing if this file is
//  ever pulled into a non-macOS target.
//

#if os(macOS)
import AppKit
import CoreGraphics

extension DisplayConfig {
    // MARK: - Detection

    @MainActor
    static func detect() -> DisplayConfig {
        let screen = NSApp.keyWindow?.screen
                  ?? NSApp.mainWindow?.screen
                  ?? NSScreen.main
                  ?? NSScreen.screens.first!

        // NSScreen.frame is in logical points. A 4K/5K display at 2× HiDPI reports
        // 1920×1080 here, which is the resolution Sunshine should encode at.
        let w = Int(screen.frame.width)  & ~1  // align to even (H.264/HEVC requirement)
        let h = Int(screen.frame.height) & ~1

        let fps = min(screen.maximumFramesPerSecond, 120)
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        return DisplayConfig(width: w, height: h, fps: fps, hdr: hdr)
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
#endif

//
//  PyroWaveBitrate.swift
//  ChloroFrame
//
//  Default total bitrate for a PyroWave stream when the user has no override, following the
//  codec author's guide quoted in vibeshine/docs/pyrowave-protocol.md ("Rate control",
//  35 dB PSNR-HVS-M-H at a viewing distance of twice the screen height).
//

import Foundation

nonisolated enum PyroWaveBitrate {
    static let minMbps = 100.0
    static let maxMbps = 2000.0

    /// Total wire bitrate in kbps. 220 Mbps at 1080p60 and 290 Mbps above it, scaling linearly
    /// with frame rate, plus 20% for HDR10 and 15% for 4:4:4 (the guide says 8 to 21%).
    static func defaultKbps(width: Int, height: Int, fps: Int, hdr10: Bool = false, yuv444: Bool = false) -> Int {
        let base60 = height <= 1080 ? 220.0 : 290.0
        var mbps = base60 * Double(fps) / 60.0
        if hdr10  { mbps *= 1.2 }
        if yuv444 { mbps *= 1.15 }
        mbps = min(max(mbps, minMbps), maxMbps)
        return Int((mbps * 1000).rounded())
    }
}

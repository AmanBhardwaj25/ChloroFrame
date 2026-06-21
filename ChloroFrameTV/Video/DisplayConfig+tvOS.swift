//
//  DisplayConfig+tvOS.swift
//  ChloroFrameTV
//
//  tvOS display detection. Per the port plan (4.1), tvOS does not enumerate
//  physical display modes. It starts from a fixed preset; a user-facing preset
//  picker arrives in a later phase. 1080p60 H.264 SDR is the first-correctness
//  default, chosen to avoid validating HDR/4K at the same time as bootstrapping
//  the target.
//

#if os(tvOS)
import Foundation

extension DisplayConfig {
    static func detect() -> DisplayConfig {
        DisplayConfig(width: 1920, height: 1080, fps: 60, hdr: false)
    }
}
#endif

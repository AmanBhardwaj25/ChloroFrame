//
//  PyroWaveVendor.swift
//  ChloroFrame
//

import Foundation

/// Vendored from https://github.com/Themaister/pyrowave, metal/ at commit
/// a0d2e71e98b85f6a23f62407df21a39e9745b875 (Metal API 1.0.0). The wire bitstream code
/// (pyrowave_bitstream.cpp/.hpp) is identical to 186f0393b77f7755953b5ecde994bb1cec2e4155, the
/// commit vibeshine pins, so `bitstreamID` below stays the host's value and the HUD mismatch
/// check keeps comparing against what the host advertises.
/// Local patches: short-block rejection in BitstreamParser::push_packet
/// (mirrors vibeshine 0003). Re-vendor by repeating design/pyrowave-implementation-plan.md D1.
nonisolated enum PyroWaveVendor {
    static let bitstreamID = "186f0393"

    /// API version reported by the vendored library, as (major, minor, patch).
    static func apiVersion() -> (major: UInt32, minor: UInt32, patch: UInt32) {
        var major: UInt32 = 0
        var minor: UInt32 = 0
        var patch: UInt32 = 0
        pyrowave_get_api_version(&major, &minor, &patch)
        return (major, minor, patch)
    }
}

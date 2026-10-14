//
//  PyroWaveVendor.swift
//  ChloroFrame
//

import Foundation

/// Vendored from https://github.com/Themaister/pyrowave, metal/ at commit
/// 186f0393b77f7755953b5ecde994bb1cec2e4155 (the commit vibeshine pins).
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

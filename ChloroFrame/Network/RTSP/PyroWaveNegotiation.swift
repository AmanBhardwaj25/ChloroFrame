//
//  PyroWaveNegotiation.swift
//  ChloroFrame
//
//  The PyroWave-only decisions RTSPClient.negotiate makes after DESCRIBE, split out as a pure
//  function so they can be unit tested. H.264, HEVC and AV1 never reach this code.
//  See design/pyrowave-implementation-plan.md D5 and decisions Q2 and Q4.
//

import Foundation

nonisolated enum PyroWaveNegotiation {

    struct Outcome {
        /// The config to announce. Equals the input unless the request was downgraded.
        var config: StreamConfig
        /// Why the request was downgraded to HEVC, nil when PyroWave stays.
        var downgradeReason: String?
        /// The host advertised PyroWave with a bitstream id other than the vendored one (or
        /// with no id at all). Decision Q2: continue, and surface a HUD warning.
        var bitstreamMismatch: Bool
    }

    /// Call only when `config.codec == .pyrowave`.
    static func resolve(config: StreamConfig, sdp: SDPInfo, networkClass: StreamNetworkClass) -> Outcome {
        var result = config
        let reason: String?
        if !sdp.advertisesPyroWave {
            reason = "server did not advertise PyroWave"
        } else if networkClass == .remote {
            reason = "PyroWave is not offered on remote routes"
        } else {
            reason = nil
        }

        if let reason {
            result.codec = .hevc
            result.yuv444 = false
            if let fallback = config.fallbackBitrateKbps { result.bitrate = fallback }
            return Outcome(config: result, downgradeReason: reason, bitstreamMismatch: false)
        }
        return Outcome(
            config: result,
            downgradeReason: nil,
            bitstreamMismatch: sdp.pyroWaveBitstreamID != PyroWaveVendor.bitstreamID
        )
    }
}

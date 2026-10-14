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

    /// The 4:4:4 decision (D8). 4:4:4 is requested only when the user asked for it AND the host
    /// advertised `SCM_PYROWAVE_444`; otherwise the stream is 4:2:0 and `fallbackReason` says why
    /// (nil when the user did not ask for 4:4:4, so nothing needs logging).
    static func chooseChroma(userWants444: Bool, hostSupports444: Bool) -> (use444: Bool, fallbackReason: String?) {
        guard userWants444 else { return (false, nil) }
        guard hostSupports444 else {
            return (false, "4:4:4 requested but the host does not advertise SCM_PYROWAVE_444, using 4:2:0")
        }
        return (true, nil)
    }

    /// The stream profile a PyroWave launch will request (D8 and D9): chroma and bit depth.
    struct Profile: Equatable {
        var chroma444: Bool
        /// 10-bit planes (the HDR10 profiles). Whether the picture is PQ or 10-bit SDR is the
        /// host's call, announced by its HDR mode message.
        var tenBit: Bool
        /// Why the profile is below what the user asked for, nil when it matches.
        var fallbackReason: String?

        var label: String { "\(chroma444 ? "4:4:4" : "4:2:0") \(tenBit ? "10-bit" : "8-bit")" }
    }

    /// Picks the best profile the host offers for what the user asked for. `hostSCM` is the
    /// serverinfo `ServerCodecModeSupport` value. `userWantsHDR` means the user wants HDR AND
    /// the display and app can carry it (the same `wantHdr` the launch computes).
    ///
    /// Order when both are asked for follows the spec's client: HDR10 4:4:4, then HDR10 4:2:0,
    /// then 4:4:4 8-bit, then 4:2:0 8-bit. Chroma is never upgraded unasked, except that a
    /// host offering only `SCM_PYROWAVE_HDR10_444` serves a plain HDR request with it.
    /// Callers have already required `SCM_PYROWAVE` (8-bit 4:2:0) for PyroWave at all.
    static func chooseProfile(userWants444: Bool, userWantsHDR: Bool, hostSCM: Int) -> Profile {
        let has444 = hostSCM & ServerInfo.scmPyroWave444 != 0
        let hdr420 = hostSCM & ServerInfo.scmPyroWaveHDR10 != 0
        let hdr444 = hostSCM & ServerInfo.scmPyroWaveHDR10_444 != 0

        if userWantsHDR {
            if userWants444, hdr444 { return Profile(chroma444: true, tenBit: true, fallbackReason: nil) }
            if hdr420 {
                let reason = userWants444 ? "HDR10 4:4:4 requested but the host does not advertise SCM_PYROWAVE_HDR10_444, using HDR10 4:2:0" : nil
                return Profile(chroma444: false, tenBit: true, fallbackReason: reason)
            }
            if hdr444 {
                return Profile(chroma444: true, tenBit: true,
                               fallbackReason: userWants444 ? nil : "host offers only SCM_PYROWAVE_HDR10_444, using HDR10 4:4:4")
            }
            // No 10-bit profile: fall through to 8-bit SDR, and say that HDR was dropped.
            let chroma = chooseChroma(userWants444: userWants444, hostSupports444: has444)
            let base = "HDR requested but the host does not advertise SCM_PYROWAVE_HDR10 or SCM_PYROWAVE_HDR10_444, using 8-bit SDR"
            return Profile(chroma444: chroma.use444, tenBit: false,
                           fallbackReason: base + (chroma.fallbackReason.map { "; " + $0 } ?? ""))
        }
        let chroma = chooseChroma(userWants444: userWants444, hostSupports444: has444)
        return Profile(chroma444: chroma.use444, tenBit: false, fallbackReason: chroma.fallbackReason)
    }

    /// Whether "the app supports HDR" holds when no app is chosen yet (the readiness button and
    /// Test network), from the app list's `IsHdrSupported` flags. Vibeshine sets that flag the
    /// same for every app (nvhttp.cpp, from HEVC or AV1 Main10), so any app stands for all, and
    /// those actions then compute the same profile and bitrate as a launch. An empty list
    /// counts as yes.
    static func hostAppsSupportHDR(_ appFlags: [Bool]) -> Bool {
        appFlags.isEmpty || appFlags.contains(true)
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

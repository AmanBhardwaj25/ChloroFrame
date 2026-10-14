//
//  VideoCapabilities.swift
//  ChloroFrame
//
//  Single source of truth for what the *local* device can decode.
//  Used to gate codec options in the UI so we never advertise a codec to the
//  host that this Mac/Apple TV has no hardware decoder for.
//

import Metal
import VideoToolbox

enum VideoCapabilities {

    /// True when this device has a hardware AV1 decoder VideoToolbox can use.
    ///
    /// AV1 hardware decode exists only on newer Apple silicon (for example
    /// M3-class and later, A17 Pro and later, and the Apple TV models built on
    /// those SoCs). On everything else `VTIsHardwareDecodeSupported` returns
    /// false and we must not offer AV1 — requesting it would yield a black
    /// screen because the decoder requires hardware
    /// (RequireHardwareAcceleratedVideoDecoder) with no software fallback.
    ///
    /// Probed once and cached; the answer cannot change during a run.
    static let supportsAV1Hardware: Bool = {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()

    /// True when this device's GPU can run the vendored PyroWave Metal decoder
    /// (Apple7 family or newer with 32-wide SIMD groups). False on Intel Macs.
    /// Probed once and cached; the answer cannot change during a run.
    static let supportsPyroWave: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return pyrowave_device_is_supported(Unmanaged.passUnretained(device).toOpaque())
    }()
}

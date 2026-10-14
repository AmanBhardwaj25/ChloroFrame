//
//  PyroWaveDevice.swift
//  ChloroFrame
//
//  Owns the shared `pyrowave_device` for one MTLDevice. Creation compiles the
//  decode pipelines from MSL source at runtime, which is the slowest step of
//  PyroWave setup, so it happens once per MTLDevice and is cached for the app's
//  lifetime. Decoders and encoders created from it must be destroyed first; the
//  cache never evicts, so that holds naturally.
//

import Foundation
import Metal
import QuartzCore

nonisolated enum PyroWaveError: Error, CustomStringConvertible {
    case unsupportedDevice
    case failed(String, code: Int32)
    case invalidFormat(String)

    var description: String {
        switch self {
        case .unsupportedDevice:
            return "this GPU cannot run the PyroWave decoder"
        case .failed(let what, let code):
            return "\(what) failed (\(code))"
        case .invalidFormat(let why):
            return "invalid PyroWave format: \(why)"
        }
    }
}

nonisolated final class PyroWaveDevice: @unchecked Sendable {

    let mtlDevice: MTLDevice
    let handle: pyrowave_device
    /// Wall-clock cost of `pyrowave_device_create`, for logging.
    let creationMs: Double

    private init(mtlDevice: MTLDevice, handle: pyrowave_device, creationMs: Double) {
        self.mtlDevice = mtlDevice
        self.handle = handle
        self.creationMs = creationMs
    }

    deinit { pyrowave_device_destroy(handle) }

    // MARK: - Per-MTLDevice cache

    private static let lock = NSLock()
    private static var cache: [UInt64: PyroWaveDevice] = [:]

    /// Returns the shared device for `device`, creating it on first use. The first call
    /// blocks for the shader compile, so call it (or `warmUp`) off the main thread.
    static func shared(for device: MTLDevice) throws -> PyroWaveDevice {
        lock.lock()
        defer { lock.unlock() }

        if let existing = cache[device.registryID] { return existing }

        let opaque = Unmanaged.passUnretained(device).toOpaque()
        guard pyrowave_device_is_supported(opaque) else { throw PyroWaveError.unsupportedDevice }

        var info = pyrowave_device_create_info(mtl_device: opaque,
                                               message_callback: nil,
                                               message_userdata: nil)
        var created: pyrowave_device?
        let start = CACurrentMediaTime()
        let result = pyrowave_device_create(&info, &created)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        guard result == PYROWAVE_SUCCESS, let created else {
            throw PyroWaveError.failed("pyrowave_device_create", code: result.rawValue)
        }

        print("[PyroWave] device created in \(String(format: "%.0f", elapsedMs)) ms")
        let wrapped = PyroWaveDevice(mtlDevice: device, handle: created, creationMs: elapsedMs)
        cache[device.registryID] = wrapped
        return wrapped
    }

    /// Starts shader compilation on a background queue so a later `shared(for:)` is a
    /// cache hit. Safe to call repeatedly.
    static func warmUp(device: MTLDevice) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try shared(for: device)
            } catch {
                print("[PyroWave] warm-up failed: \(error)")
            }
        }
    }
}

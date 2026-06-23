//
//  FrameInterpolator.swift
//  ChloroFrame
//
//  Temporal frame generation via VideoToolbox's low-latency frame interpolation
//  (VTFrameProcessor, macOS 26+, Apple Silicon).
//
//  Sits at the decode -> enqueue seam:
//
//    decode -> FrameInterpolator.submit -> onFrame (interpolated + real) -> enqueueFrame
//
//  For each consecutive pair of decoded frames it synthesizes one midpoint frame,
//  doubling the effective frame rate fed to the renderer. Spatial upscaling (MetalFX)
//  stays in the renderer and runs on every frame this emits, real or synthesized.
//
//  Latency: the midpoint frame depends on the *next* real frame, so even pacing costs
//  about one source-frame interval of added latency. This is inherent to interpolation,
//  which is why it is opt-in.
//

import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

enum InterpolatorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class FrameInterpolator {

    /// Emits frames in presentation order: the interpolated midpoint frame, then the real
    /// frame. The first frame of a stream (no predecessor) passes through unchanged.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let processor = VTFrameProcessor()
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "chloroframe.interpolate", qos: .userInteractive)
    private var prevBuffer: CVPixelBuffer?
    private var prevPTS: CMTime = .invalid
    private var errLogCount = 0
    // Backpressure: number of submitted frames not yet finished. When >1 we are falling
    // behind real time, so we skip interpolation to drain the backlog rather than let
    // latency grow without bound.
    private let pendingLock = NSLock()
    private var pending = 0

    // Interpolation phases (uniform within the VT-supported 1/2^x grid): [0.5] for 2x,
    // [0.25,0.5,0.75] for 4x. The number of inserted frames per real pair is phaseValues.count.
    private let multiplier: Int
    private let phaseValues: [Double]
    private let interpPhases: [Float]

    /// - Parameter multiplier: 2 (one inserted frame at 0.5) or 4 (three at 0.25/0.5/0.75).
    init(width: Int, height: Int, sourcePixelFormat: OSType, multiplier: Int) throws {
        let mult = multiplier >= 4 ? 4 : 2
        self.multiplier = mult
        self.phaseValues = mult == 4 ? [0.25, 0.5, 0.75] : [0.5]
        self.interpPhases = phaseValues.map { Float($0) }
        let configFrames = mult == 4 ? 2 : 1   // VT x: exposes 2^x - 1 phases

        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw InterpolatorError.message("frame interp unavailable on device")
        }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: configFrames) else {
            throw InterpolatorError.message("src \(width)×\(height) not supported")
        }

        let supportedFormats = config.__frameSupportedPixelFormats.map { OSType(truncatingIfNeeded: $0.intValue) }
        guard supportedFormats.contains(sourcePixelFormat) else {
            throw InterpolatorError.message("\(Self.fourCC(sourcePixelFormat)) not accepted")
        }

        do {
            try processor.startSession(configuration: config)
        } catch {
            throw InterpolatorError.message("session: \(error.localizedDescription)")
        }

        guard let p = Self.makePool(width: width, height: height,
                                    attributes: config.destinationPixelBufferAttributes) else {
            processor.endSession()
            throw InterpolatorError.message("pool alloc failed")
        }
        self.pool = p
        Swift.print("[ChloroFrame][interp] frame generation \(width)x\(height) \(mult)x")
    }

    deinit { processor.endSession() }

    /// Drop the held predecessor so we never interpolate across a stream discontinuity
    /// (IDR after loss). Call from the clock-reset path.
    func reset() {
        queue.async { [weak self] in
            self?.prevBuffer = nil
            self?.prevPTS = .invalid
        }
    }

    func submit(_ buffer: CVPixelBuffer, pts: CMTime) {
        pendingLock.lock(); pending += 1; pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock(); let backlogged = self.pending > 2; self.pendingLock.unlock()
            self.process(buffer, pts: pts, skipInterp: backlogged)
            self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
        }
    }

    private func process(_ buffer: CVPixelBuffer, pts: CMTime, skipInterp: Bool) {
        defer { prevBuffer = buffer; prevPTS = pts }

        guard !skipInterp, let prev = prevBuffer, prevPTS.isValid, let pool = pool else {
            // First frame, or falling behind: pass the real frame straight through.
            onFrame?(buffer, pts)
            return
        }

        guard let srcFrame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts),
              let preFrame = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: prevPTS) else {
            onFrame?(buffer, pts); return
        }

        // One destination buffer per phase, in phase order.
        let delta = CMTimeSubtract(pts, prevPTS)
        var destBufs: [CVPixelBuffer] = []
        var destFrames: [VTFrameProcessorFrame] = []
        var destPTSs: [CMTime] = []
        for ph in phaseValues {
            var dest: CVPixelBuffer?
            let phPTS = CMTimeAdd(prevPTS, CMTimeMultiplyByRatio(delta, multiplier: Int32((ph * 1000).rounded()), divisor: 1000))
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dest) == kCVReturnSuccess,
                  let destBuf = dest,
                  let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: phPTS) else {
                onFrame?(buffer, pts); return
            }
            destBufs.append(destBuf); destFrames.append(destFrame); destPTSs.append(phPTS)
        }

        guard let params = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: srcFrame, previousFrame: preFrame,
            interpolationPhase: interpPhases, destinationFrames: destFrames) else {
            onFrame?(buffer, pts); return
        }

        // Serialize (one in flight) so emitted frames stay in pts order. The completion runs
        // on a VideoToolbox-internal queue, so this wait does not deadlock.
        let done = DispatchSemaphore(value: 0)
        var ok = false
        processor.process(parameters: params) { [weak self] _, error in
            if let error { self?.logErr("process: \(error.localizedDescription)") }
            else { ok = true }
            done.signal()
        }
        done.wait()

        if ok {
            for i in destBufs.indices { onFrame?(destBufs[i], destPTSs[i]) }   // inserted frames in order
        }
        onFrame?(buffer, pts)                                                   // then the real frame
    }

    private func logErr(_ message: String) {
        guard errLogCount < 5 else { return }
        errLogCount += 1
        Swift.print("[ChloroFrame][interp] \(message)")
    }

    private static func fourCC(_ f: OSType) -> String {
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  return "NV12"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "P010"
        default:
            let bytes = [UInt8((f >> 24) & 0xFF), UInt8((f >> 16) & 0xFF),
                         UInt8((f >> 8) & 0xFF), UInt8(f & 0xFF)]
            return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(f, radix: 16, uppercase: true))"
        }
    }

    private static func makePool(width: Int, height: Int,
                                 attributes: [String: Any]) -> CVPixelBufferPool? {
        var attrs = attributes
        attrs[kCVPixelBufferWidthKey as String]  = width
        attrs[kCVPixelBufferHeightKey as String] = height
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                      attrs as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }
}

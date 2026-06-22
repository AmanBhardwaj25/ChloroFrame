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

    init(width: Int, height: Int, sourcePixelFormat: OSType) throws {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw InterpolatorError.message("frame interp unavailable on device")
        }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
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
        Swift.print("[ChloroFrame][interp] frame generation \(width)x\(height) 2x")
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
        queue.async { [weak self] in self?.process(buffer, pts: pts) }
    }

    private func process(_ buffer: CVPixelBuffer, pts: CMTime) {
        defer { prevBuffer = buffer; prevPTS = pts }

        guard let prev = prevBuffer, prevPTS.isValid, let pool = pool else {
            onFrame?(buffer, pts)   // first frame: nothing to interpolate from
            return
        }

        let midPTS = CMTimeAdd(prevPTS, CMTimeMultiplyByRatio(CMTimeSubtract(pts, prevPTS), multiplier: 1, divisor: 2))

        guard let srcFrame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts),
              let preFrame = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: prevPTS) else {
            onFrame?(buffer, pts); return
        }

        var dest: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dest) == kCVReturnSuccess,
              let destBuf = dest,
              let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: midPTS) else {
            onFrame?(buffer, pts); return
        }

        guard let params = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: srcFrame, previousFrame: preFrame,
            interpolationPhase: [0.5], destinationFrames: [destFrame]) else {
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

        if ok { onFrame?(destBuf, midPTS) }   // interpolated midpoint first
        onFrame?(buffer, pts)                 // then the real frame
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

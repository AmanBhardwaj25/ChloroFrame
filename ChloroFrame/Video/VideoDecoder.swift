//
//  VideoDecoder.swift
//  ChloroFrame
//

import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore

// Per-frame data threaded through VTDecompressionSessionDecodeFrame's frameRefcon parameter.
// Avoids shared instance-level mutable state for values that belong to a single decode job.
// Lifetime: retained through frameRefcon and consumed by the output callback. This keeps the
// per-frame metadata valid even if VideoToolbox ever delivers a callback later than expected.
private final class FrameContext {
    let submitTime: Double
    let resetClock: Bool
    init(submitTime: Double, resetClock: Bool) {
        self.submitTime = submitTime
        self.resetClock = resetClock
    }
}

class VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var currentFormatDescription: CMFormatDescription?

    var onFrameDecoded: ((CVPixelBuffer, CMTime) -> Void)?
    /// Fired from the decode thread immediately before the first post-loss IDR is passed to
    /// onFrameDecoded. Wire this to renderer.resetClockAnchor() so the anchor clears at exactly
    /// the right point in the decode pipeline, not at loss-detection time.
    var onClockReset: (() -> Void)?
    var stats: StreamStatsCollector?
    var isHdr: Bool = false
    var isReady: Bool { decompressionSession != nil }

    private var firstFrameLogged = false

    // Opt-F: dedicated userInteractive queue isolates VT session work from the RTP receive thread.
    private let decodeQueue = DispatchQueue(label: "chloroframe.video-decode", qos: .userInteractive)

    init() {}

    deinit { invalidate() }

    func setup(for formatDescription: CMFormatDescription) throws {
        invalidate()

        // SDR: NV12 (8-bit, 420v).  HDR10: P010 (10-bit MSB-aligned in 16-bit, x420).
        let pixelFormat = isHdr
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let destinationImageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]

        let sessionConfiguration: [CFString: Any] = [
            kVTDecompressionPropertyKey_RealTime: true,
        ]

        var session: VTDecompressionSession?
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (refCon, frameRefCon, status, infoFlags, imageBuffer, pts, duration) in
                guard let refCon else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                let ctx = frameRefCon.map {
                    Unmanaged<FrameContext>.fromOpaque($0).takeRetainedValue()
                }
                guard status == noErr, let imageBuffer, let ctx else {
                    decoder.stats?.recordFrameDropped()
                    return
                }
                decoder.handleDecodedFrame(imageBuffer, pts: pts, context: ctx)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw VideoDecoderError.failedToCreateSession(status)
        }

        for (key, value) in sessionConfiguration {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        // Suppress VT's internal B-frame reorder buffer. Game streams have no B-frames, so
        // the buffer adds latency without benefit. Key is semi-private; CFString approach required.
        let mflStatus = VTSessionSetProperty(session,
                                             key: "MaximumFrameLatency" as CFString,
                                             value: 0 as CFNumber)
        print("[VideoDecoder] MaximumFrameLatency=0 → \(mflStatus == noErr ? "OK" : "unsupported (status \(mflStatus))")")

        self.decompressionSession = session
        self.currentFormatDescription = formatDescription
    }

    /// Enqueue a NAL unit for decoding. When `resetClockBeforeOutput` is true the clock anchor
    /// is cleared atomically inside the same decode job, so the reset is irrevocably tied to
    /// this specific frame rather than relying on a separately queued flag landing first.
    func decode(nalUnit: Data, presentationTime: CMTime, resetClockBeforeOutput: Bool = false) {
        decodeQueue.async { [weak self] in
            self?.decodeOnQueue(nalUnit: nalUnit, presentationTime: presentationTime,
                                resetClockBeforeOutput: resetClockBeforeOutput)
        }
    }

    private func decodeOnQueue(nalUnit: Data, presentationTime: CMTime, resetClockBeforeOutput: Bool) {
        guard let session = decompressionSession else {
            stats?.recordFrameDropped()
            return
        }

        // Bridge to NSData for a stable pointer. kCFAllocatorNull tells CoreMedia not to free
        // the backing bytes — nsData (and therefore the buffer) stays alive for the duration
        // of this stack frame, which covers the synchronous VTDecompressionSessionDecodeFrame
        // call below (flags: [] fires the callback before returning).
        let nsData = nalUnit as NSData

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: nsData.bytes),
            blockLength: nsData.length,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: nsData.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            stats?.recordFrameDropped()
            return
        }

        guard let formatDesc = currentFormatDescription else {
            stats?.recordFrameDropped()
            return
        }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [nsData.length],
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            stats?.recordFrameDropped()
            return
        }

        // submitTime and resetClock travel through frameRefcon, eliminating the shared
        // decodeSubmitTime/pendingClockReset instance vars. Retain the context for VT and let
        // the output callback consume it with takeRetainedValue().
        let ctx = FrameContext(submitTime: CACurrentMediaTime(), resetClock: resetClockBeforeOutput)
        let ctxRef = Unmanaged.passRetained(ctx)
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: ctxRef.toOpaque(),
            infoFlagsOut: &infoFlags
        )

        if decodeStatus != noErr {
            ctxRef.release()
            stats?.recordFrameDropped()
        }
    }

    private func handleDecodedFrame(_ imageBuffer: CVImageBuffer, pts: CMTime, context: FrameContext) {
        let latencyMs = (CACurrentMediaTime() - context.submitTime) * 1000.0
        stats?.recordFrameDecoded(latencyMs: latencyMs)
        if !firstFrameLogged {
            firstFrameLogged = true
            logFirstFrameMetadata(imageBuffer)
        }
        if context.resetClock { onClockReset?() }
        onFrameDecoded?(imageBuffer, pts)
    }

    private func logFirstFrameMetadata(_ imageBuffer: CVImageBuffer) {
        let fmt       = CVPixelBufferGetPixelFormatType(imageBuffer)
        let primaries = CVBufferCopyAttachment(imageBuffer, kCVImageBufferColorPrimariesKey,   nil) as? String ?? "nil"
        let transfer  = CVBufferCopyAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil) as? String ?? "nil"
        let matrix    = CVBufferCopyAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey,      nil) as? String ?? "nil"

        let fmtStr: String
        switch fmt {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: fmtStr = "P010"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  fmtStr = "NV12"
        default: fmtStr = "0x\(String(fmt, radix: 16, uppercase: true))"
        }

        // True HDR: P010 + PQ (ST.2084) transfer + BT.2020 primaries + BT.2020 matrix.
        // Must match the three-field check in MetalVideoRenderer.render().
        // HLG is intentionally excluded — its EOTF is different and not implemented in the shader.
        let isP010      = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let isActualHDR = isP010
                       && transfer  == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                       && primaries == (kCVImageBufferColorPrimaries_ITU_R_2020          as String)
                       && matrix    == (kCVImageBufferYCbCrMatrix_ITU_R_2020             as String)

        stats?.setReceivedHdr(isActualHDR)
        print("[VideoDecoder] first frame: fmt=\(fmtStr) tf=\(transfer) primaries=\(primaries) matrix=\(matrix) requestedHDR=\(isHdr) actualHDR=\(isActualHDR)")
    }

    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        firstFrameLogged = false
    }
}

enum VideoDecoderError: Error {
    case failedToCreateSession(OSStatus)
    case invalidFormat
}

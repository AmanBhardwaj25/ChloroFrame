//
//  HDRFrameGenerator.swift
//  ChloroFrame
//
//  EXPERIMENTAL optical-flow frame generation for HDR (P010) streams.
//
//  VideoToolbox's low-latency frame interpolation rejects P010, so for HDR we synthesize the
//  midpoint frame ourselves: estimate motion with Vision optical flow, then warp the previous
//  and current frames toward the middle along that flow and blend. Output is P010 again, so the
//  renderer's existing HDR path displays it with no changes.
//
//  Prototype limitations (expected):
//   - Blends in the stored PQ-encoded YUV domain, not linear light (cheap; slightly wrong in
//     highlights across large motion).
//   - Single forward flow with symmetric gather; occlusions and scene cuts will artifact.
//   - Vision optical flow per frame is not free; this is a quality/latency experiment.
//
//  Sits at the decode->enqueue seam like FrameInterpolator. Adds ~one source-frame interval
//  of latency (the midpoint depends on the next real frame).
//

import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import Metal
import Vision

final class HDRFrameGenerator {

    /// Emits frames in presentation order: the synthesized midpoint frame, then the real frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let warpYPSO: MTLRenderPipelineState
    private let warpUVPSO: MTLRenderPipelineState
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "chloroframe.hdr-framegen", qos: .userInteractive)

    private var prevBuffer: CVPixelBuffer?
    private var prevPTS: CMTime = .invalid
    private var logCount = 0
    // Backpressure: optical flow + the GPU wait are expensive, so when we fall behind real
    // time we skip synthesis and pass the real frame through, keeping latency bounded.
    private let pendingLock = NSLock()
    private var pending = 0

    // Phases (evenly spaced) of the frames to synthesize per real pair. n inserted frames ->
    // phases i/(n+1). Our warp does arbitrary phases, so any count works (2x: [0.5], 3x:
    // [1/3,2/3], 4x: [0.25,0.5,0.75]).
    private let phaseValues: [Double]

    /// - Parameter interpolatedFrames: number of frames to synthesize between each real pair
    ///   (1 = 2x, 2 = 3x, 3 = 4x).
    init(width: Int, height: Int, interpolatedFrames: Int) throws {
        let n = max(1, min(3, interpolatedFrames))
        self.phaseValues = (1...n).map { Double($0) / Double(n + 1) }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw InterpolatorError.message("no Metal device")
        }
        self.device = device
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary() else {
            throw InterpolatorError.message("no shader library")
        }
        func pso(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vertexShader")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        self.warpYPSO  = try pso("fragmentWarpBlendY",  .r16Unorm)
        self.warpUVPSO = try pso("fragmentWarpBlendUV", .rg16Unorm)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw InterpolatorError.message("texture cache failed")
        }
        self.textureCache = cache

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                      attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw InterpolatorError.message("P010 pool alloc failed")
        }
        self.pool = pool
        Swift.print("[ChloroFrame][hdr-fg] optical-flow frame generation \(width)x\(height) \(n + 1)x")
    }

    deinit {
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    /// Drop the held predecessor so we never interpolate across a discontinuity (IDR after loss).
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

        guard !skipInterp, let prev = prevBuffer, prevPTS.isValid else {
            // First frame, or falling behind: pass the real frame straight through.
            onFrame?(buffer, pts)
            return
        }

        let delta = CMTimeSubtract(pts, prevPTS)
        let frames = makeFrames(prev: prev, cur: buffer)
        for (buf, ph) in frames {   // synthesized frames in phase order
            let phPTS = CMTimeAdd(prevPTS, CMTimeMultiplyByRatio(delta, multiplier: Int32((ph * 1000).rounded()), divisor: 1000))
            onFrame?(buf, phPTS)
        }
        onFrame?(buffer, pts)        // then the real frame
    }

    /// Computes optical flow once, then warps both frames toward each configured phase, returning
    /// the synthesized P010 buffers paired with their phase.
    private func makeFrames(prev: CVPixelBuffer, cur: CVPixelBuffer) -> [(CVPixelBuffer, Double)] {
        guard let cache = textureCache, let pool = pool else { return [] }

        // Optical flow prev -> cur (Vision: handler image = prev, target = cur).
        guard let flowBuffer = opticalFlow(from: prev, to: cur) else { return [] }

        let w = CVPixelBufferGetWidth(cur), h = CVPixelBufferGetHeight(cur)
        let read: [String: Any] = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue]
        let rt:   [String: Any] = [kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue]

        // Source textures + flow, computed once and reused for every phase. Keep CVMetalTexture
        // refs alive until the GPU finishes (waitUntilCompleted below).
        guard let yAref  = cvTexture(prev, .r16Unorm,  w,     h,     0, read, cache),
              let uvAref = cvTexture(prev, .rg16Unorm, w / 2, h / 2, 1, read, cache),
              let yBref  = cvTexture(cur,  .r16Unorm,  w,     h,     0, read, cache),
              let uvBref = cvTexture(cur,  .rg16Unorm, w / 2, h / 2, 1, read, cache),
              let flowRef = cvTextureFlow(flowBuffer, cache),
              let yA = CVMetalTextureGetTexture(yAref), let uvA = CVMetalTextureGetTexture(uvAref),
              let yB = CVMetalTextureGetTexture(yBref), let uvB = CVMetalTextureGetTexture(uvBref),
              let flow = CVMetalTextureGetTexture(flowRef) else {
            logErr("texture creation failed")
            return []
        }

        guard let cb = commandQueue.makeCommandBuffer() else { return [] }

        var outputs: [(CVPixelBuffer, Double)] = []
        var destRefs: [CVMetalTexture] = []   // retain dest textures through completion
        for ph in phaseValues {
            var dest: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dest) == kCVReturnSuccess,
                  let destBuf = dest else { continue }
            CVBufferPropagateAttachments(cur, destBuf)   // carry HDR color tags
            guard let dYref  = cvTexture(destBuf, .r16Unorm,  w,     h,     0, rt, cache),
                  let dUVref = cvTexture(destBuf, .rg16Unorm, w / 2, h / 2, 1, rt, cache),
                  let dY = CVMetalTextureGetTexture(dYref), let dUV = CVMetalTextureGetTexture(dUVref) else {
                continue
            }
            encodeWarp(cb, pso: warpYPSO,  a: yA,  b: yB,  flow: flow, dst: dY,  phase: Float(ph))
            encodeWarp(cb, pso: warpUVPSO, a: uvA, b: uvB, flow: flow, dst: dUV, phase: Float(ph))
            destRefs.append(dYref); destRefs.append(dUVref)
            outputs.append((destBuf, ph))
        }

        cb.commit()
        cb.waitUntilCompleted()
        _ = (yAref, uvAref, yBref, uvBref, flowRef, destRefs)   // retain through completion
        return outputs
    }

    private func encodeWarp(_ cb: MTLCommandBuffer, pso: MTLRenderPipelineState,
                            a: MTLTexture, b: MTLTexture, flow: MTLTexture, dst: MTLTexture, phase: Float) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(a, index: 0)
        enc.setFragmentTexture(b, index: 1)
        enc.setFragmentTexture(flow, index: 2)
        var ph = phase
        enc.setFragmentBytes(&ph, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func opticalFlow(from a: CVPixelBuffer, to b: CVPixelBuffer) -> CVPixelBuffer? {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: a, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logErr("optical flow: \(error.localizedDescription)")
            return nil
        }
        guard let obs = request.results?.first as? VNPixelBufferObservation else {
            logErr("optical flow: no result")
            return nil
        }
        return obs.pixelBuffer
    }

    private func cvTexture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat,
                           _ width: Int, _ height: Int, _ plane: Int,
                           _ attrs: [String: Any], _ cache: CVMetalTextureCache) -> CVMetalTexture? {
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, attrs as CFDictionary,
            format, width, height, plane, &ref) == kCVReturnSuccess else { return nil }
        return ref
    }

    private func cvTextureFlow(_ buffer: CVPixelBuffer, _ cache: CVMetalTextureCache) -> CVMetalTexture? {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let attrs: [String: Any] = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue]
        return cvTexture(buffer, .rg32Float, w, h, 0, attrs, cache)
    }

    private func logErr(_ message: String) {
        guard logCount < 5 else { return }
        logCount += 1
        Swift.print("[ChloroFrame][hdr-fg] \(message)")
    }
}

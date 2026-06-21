//
//  MetalVideoRenderer.swift
//  ChloroFrame
//
//  Shared Metal video renderer, split out of MetalVideoView.swift so both the
//  macOS (NSView) and tvOS (UIView) hosts can drive it. It operates only on a
//  CAMetalLayer plus Metal/CoreVideo/CoreMedia, all of which exist on both
//  platforms, so this file is framework-agnostic (no AppKit/UIKit). The platform
//  view owns the CADisplayLink and calls renderTick(now:targetTimestamp:).
//

import Foundation
import Metal
import CoreMedia
import CoreVideo
import QuartzCore

/// Handles Metal rendering of decoded NV12/P010 video frames via CVMetalTextureCache.
/// Zero-copy: CVPixelBuffer IOSurfaces are vended directly as Y + UV Metal textures.
///
/// Both PSOs target rgba16Float so the same drawable can serve either path. Shader/texture
/// selection is driven entirely by the decoded pixel buffer at render time:
///   - Texture format: P010 → r16Unorm/rg16Unorm; NV12 → r8Unorm/rg8Unorm
///   - Shader: confirmed PQ+BT.2020 → fragmentShaderYUVHDR; everything else → fragmentShaderYUV
///   - "Confirmed HDR" = P010 AND (PQ or HLG transfer function) AND BT.2020 primaries
///
/// When HDR-ness changes, the CAMetalLayer is updated:
///   - EDR on → colorspace = extendedLinearITUR_2020 (macOS maps BT.2020 linear → display native)
///   - EDR off → colorspace = nil
///
/// isHdr (from RTSP negotiation) is used only for the initial layer pre-warm; frame metadata
/// is the authoritative source starting from the first decoded frame.
private struct QueuedFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime          // Monotonic presentation time.
    let enqueuedAt: Double   // CACurrentMediaTime() at enqueue
    var targetWall: Double   // CACurrentMediaTime() when this frame should be presented
}

class MetalVideoRenderer {
    let device: MTLDevice
    let isHdr: Bool
    var stats: StreamStatsCollector?
    private let commandQueue: MTLCommandQueue
    private let pipelineStateSDR: MTLRenderPipelineState
    private let pipelineStateHDR: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var drawableSize: CGSize = .zero
    private weak var metalLayer: CAMetalLayer?
    // nil = no frame seen yet; true/false = last confirmed mode from frame metadata
    private var lastDetectedHDR: Bool? = nil

    // Presentation queue — all fields below protected by queueLock.
    // enqueueFrame runs on the decode queue; renderTick runs on the render thread.
    private let queueLock = NSLock()
    private var frameQueue: [QueuedFrame] = []
    // PTS-to-wall clock anchor — established on first frame, reset on IDR after loss.
    private var basePTS: CMTime?
    private var baseWall: Double?      // CACurrentMediaTime() target for the first frame
    private var frameDuration: Double = 1.0 / 120.0  // updated by setStreamFps
    private var minimumBufferFrames: Double = 3.0
    private var targetBufferFrames: Double = 3.0
    private var maximumBufferFrames: Double = 6.0
    private var maxQueueDepth: Int {
        max(4, Int(ceil(targetBufferFrames)) + 3)
    }
    private var lastBufferGrowthTime: Double = 0
    // Last underflow/overwrite/late-drop event — gates buffer decay.
    private var lastStressTime: Double = 0
    private var lastBufferDecayTime: Double = 0
    // Total frames enqueued this stream — gates buffer growth during decoder warm-up.
    private var framesEnqueuedTotal: Int = 0
    // Render-thread-only state — no lock needed (only renderTick touches these).
    private var lastDrawTime: Double = 0
    private var lastRenderedBuffer: CVPixelBuffer? = nil
    // HDR metadata is constant for a given pixel format within a stream; cache the
    // three-field check so the per-frame CVBufferCopyAttachment calls happen once.
    private var cachedHDRForFormat: (format: OSType, isHDR: Bool)? = nil
    private var enqueueLogCount = 0
    private var rebaseLogCount = 0   // decode-thread-only (enqueueFrame)
    private var presentLogCount = 0
    private var repeatedDrawsSincePresent = 0
    private var repeatStallLogCount = 0
    private var textureFailureLogCount = 0
    private var bufferGrowthLogCount = 0

    // Always rgba16Float: SDR shader outputs [0,1] (harmless in 16f), HDR shader outputs
    // extended-range values. A single format lets both PSOs share the same drawable/layer.
    var drawablePixelFormat: MTLPixelFormat { .rgba16Float }

    init?(isHdr: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.isHdr = isHdr

        guard let (sdrPSO, hdrPSO) = Self.makeRenderPipelines(device: device) else { return nil }
        self.pipelineStateSDR = sdrPSO
        self.pipelineStateHDR = hdrPSO

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    private static func makeRenderPipelines(device: MTLDevice) -> (MTLRenderPipelineState, MTLRenderPipelineState)? {
        let library = device.makeDefaultLibrary()

        let sdrDesc = MTLRenderPipelineDescriptor()
        sdrDesc.vertexFunction   = library?.makeFunction(name: "vertexShader")
        sdrDesc.fragmentFunction = library?.makeFunction(name: "fragmentShaderYUV")
        sdrDesc.colorAttachments[0].pixelFormat = .rgba16Float  // same as HDR; drawable is always rgba16Float

        let hdrDesc = MTLRenderPipelineDescriptor()
        hdrDesc.vertexFunction   = library?.makeFunction(name: "vertexShader")
        hdrDesc.fragmentFunction = library?.makeFunction(name: "fragmentShaderYUVHDR")
        hdrDesc.colorAttachments[0].pixelFormat = .rgba16Float

        guard let sdrPSO = try? device.makeRenderPipelineState(descriptor: sdrDesc),
              let hdrPSO = try? device.makeRenderPipelineState(descriptor: hdrDesc) else { return nil }
        return (sdrPSO, hdrPSO)
    }

    func updateDrawableSize(_ size: CGSize) {
        drawableSize = size
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    func attach(layer: CAMetalLayer) {
        metalLayer = layer
        // Use confirmed metadata if we have it (SwiftUI may call attach again via updateNSView
        // after the first frame is decoded — don't let that reset lastDetectedHDR back to the
        // negotiated guess). Fall back to isHdr only before any frame has been seen.
        let effectiveHDR = lastDetectedHDR ?? isHdr
        // wantsExtendedDynamicRangeContent is macOS-only. tvOS is SDR for now (HDR is a
        // later phase), so effectiveHDR is false there and the EDR opt-in is simply skipped.
        #if os(macOS)
        layer.wantsExtendedDynamicRangeContent = effectiveHDR
        #endif
        layer.colorspace = effectiveHDR ? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) : nil
    }

    func setStreamFps(_ fps: Int) {
        queueLock.lock()
        frameDuration = fps > 0 ? 1.0 / Double(fps) : 1.0 / 120.0
        minimumBufferFrames = fps >= 90 ? 3.0 : 2.0
        targetBufferFrames = minimumBufferFrames
        maximumBufferFrames = fps >= 90 ? 6.0 : 4.0
        lastBufferGrowthTime = 0
        lastStressTime = 0
        lastBufferDecayTime = 0
        framesEnqueuedTotal = 0
        queueLock.unlock()
    }

    func resetClockAnchor() {
        queueLock.lock()
        basePTS = nil
        baseWall = nil
        frameQueue.removeAll()
        queueLock.unlock()
        // lastRenderedBuffer is render-thread-only — don't touch it here.
        // After reset the last presented drawable stays on glass until new frames arrive.
        StreamLog.log("[ChloroFrame][video] clock anchor reset")
    }

    func enqueueFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let now = CACurrentMediaTime()

        queueLock.lock()

        if basePTS == nil {
            basePTS = pts
            baseWall = now + playoutDelay
        }

        let delta = CMTimeSubtract(pts, basePTS!)
        let deltaSeconds = CMTimeGetSeconds(delta)
        var targetWall = baseWall! + (deltaSeconds.isFinite ? deltaSeconds : 0)

        // Forward-only rebase: pts jumped ahead of the wall clock — re-anchor so this
        // frame plays at the design latency. LATE frames (targetWall in the past) are
        // deliberately NOT re-anchored: after a Wi-Fi stall the backlog burst must stay
        // "due immediately" so deadline selection skips straight to the newest frame.
        // Re-anchoring to the first (stalest) frame of a burst scheduled the entire
        // backlog into the future — the cause of multi-second presentation freezes.
        var rebaseReason: String? = nil
        if targetWall - (now + playoutDelay) > 0.25 {
            rebaseReason = "pts-jump"
            basePTS = pts
            baseWall = now + playoutDelay
            targetWall = baseWall!
        }

        var overwroteCount = 0
        while frameQueue.count >= maxQueueDepth {
            frameQueue.removeFirst()
            overwroteCount += 1
        }
        // Stress = late arrival (frame got here after it should already be on glass)
        // or queue overflow. Tick-time starvation is NOT stress: content below the
        // negotiated fps legitimately empties the queue between frames.
        var bufferGrowthLog: String? = nil
        if overwroteCount > 0 {
            lastStressTime = now
            bufferGrowthLog = growBufferLocked(now: now, reason: "overwrite")
        } else if targetWall < now - frameDuration {
            lastStressTime = now
            bufferGrowthLog = growBufferLocked(now: now, reason: "late-arrival")
        }
        frameQueue.append(QueuedFrame(pixelBuffer: pixelBuffer, pts: pts,
                                      enqueuedAt: now, targetWall: targetWall))
        framesEnqueuedTotal += 1
        let enqueueDepth = frameQueue.count  // peak depth before render can pop

        // Timeline repair: the queue is full yet its OLDEST frame is scheduled beyond
        // the design latency — contradictory, so the anchor is wrong (e.g. a post-stall
        // burst future-dated the whole queue). Shift the entire timeline back so the
        // head is due now; presents resume this tick, overwrite/late-drop trim the rest.
        var timelineShiftMs = 0.0
        if overwroteCount > 0, let head = frameQueue.first,
           head.targetWall > now + playoutDelay + frameDuration {
            let shift = head.targetWall - now
            baseWall! -= shift
            for i in frameQueue.indices { frameQueue[i].targetWall -= shift }
            timelineShiftMs = shift * 1000.0
        }

        // Clock servo: the server's capture clock and our display clock free-run, so a
        // fixed anchor drifts until frames pile up or run dry — judder at the beat
        // frequency. Steer baseWall so each frame's scheduled lead time (targetWall −
        // now at enqueue) hovers at playoutDelay. Time-based, not queue-depth-based,
        // so it works at any content fps (a 70 fps game holds the same ~ms of buffer).
        // Gain is tiny (≤0.5 ms per enqueue) so corrections are invisible; this also
        // smoothly drains latency after a buffer-target decay and rebuilds the buffer
        // after a catch-up burst flushes it.
        let bufferTimeError = (targetWall - now) - playoutDelay
        baseWall! -= max(-0.0005, min(0.0005, bufferTimeError * 0.01))

        // Buffer decay: growth is fast (stress-driven), decay is slow — after 10 s with
        // no underflow/overwrite/late-drop, step the target back toward minimum so one
        // bad Wi-Fi moment doesn't cost latency for the rest of the session.
        var bufferDecayLog: String? = nil
        if targetBufferFrames > minimumBufferFrames,
           now - lastStressTime > 10.0,
           now - lastBufferGrowthTime > 10.0,
           now - lastBufferDecayTime > 10.0 {
            targetBufferFrames = max(minimumBufferFrames, targetBufferFrames - 1.0)
            lastBufferDecayTime = now
            if StreamLog.verbose && bufferGrowthLogCount < 8 {
                bufferGrowthLogCount += 1
                bufferDecayLog = "[ChloroFrame][video] buffer target \(String(format: "%.0f", targetBufferFrames)) frames (\(String(format: "%.1f", playoutDelay * 1000.0))ms) reason=decay"
            }
        }

        let targetDelayMs = (targetWall - now) * 1000.0
        let shouldLogEnqueue = enqueueLogCount < 3
        if shouldLogEnqueue { enqueueLogCount += 1 }

        queueLock.unlock()

        // Stats call after lock release — stats uses its own separate NSLock so no deadlock,
        // but releasing queueLock first keeps the critical section short.
        // Sampling depth here captures the enqueue-time peak (queue reaches maxQueueDepth)
        // which renderTick misses because it samples after the dequeue.
        stats?.recordEnqueue(peakDepth: enqueueDepth, overwritten: overwroteCount)
        if let bufferGrowthLog { StreamLog.log(bufferGrowthLog) }
        if let bufferDecayLog { StreamLog.log(bufferDecayLog) }
        // Rebase and timeline-shift are the pacing repair mechanisms — log them
        // (rate-capped) so stalls in the field are diagnosable from the console.
        if let rebaseReason, rebaseLogCount < 16 {
            rebaseLogCount += 1
            StreamLog.log("[ChloroFrame][video] rebase reason=\(rebaseReason) pts=\(pts.value) depth=\(enqueueDepth)")
        }
        if timelineShiftMs > 0, rebaseLogCount < 16 {
            rebaseLogCount += 1
            StreamLog.log("[ChloroFrame][video] timeline shift -\(String(format: "%.0f", timelineShiftMs))ms depth=\(enqueueDepth) (queue was future-dated)")
        }
        if shouldLogEnqueue {
            StreamLog.log("[ChloroFrame][video] enqueue pts=\(pts.value) delay=\(String(format: "%.2f", targetDelayMs))ms depth=\(enqueueDepth)")
        }
    }

    private var playoutDelay: Double {
        frameDuration * targetBufferFrames
    }

    private func growBufferLocked(now: Double, reason: String) -> String? {
        // Startup grace: encoder/decoder warm-up jitter is not network stress —
        // growing here permanently inflated latency (observed: 3 → 6 frames in the
        // opening seconds of every stream; the erratic-RTP warm-up window lasts
        // several seconds, so the grace covers ~5 s at 120 fps).
        guard framesEnqueuedTotal >= 600 else { return nil }
        guard targetBufferFrames < maximumBufferFrames else { return nil }
        guard now - lastBufferGrowthTime > 0.5 else { return nil }

        targetBufferFrames = min(maximumBufferFrames, targetBufferFrames + 1.0)
        lastBufferGrowthTime = now

        guard StreamLog.verbose, bufferGrowthLogCount < 8 else { return nil }
        bufferGrowthLogCount += 1
        return "[ChloroFrame][video] buffer target \(String(format: "%.0f", targetBufferFrames)) frames (\(String(format: "%.1f", playoutDelay * 1000.0))ms) reason=\(reason)"
    }

    /// One display-link tick. Runs on the dedicated render thread.
    /// - Parameters:
    ///   - now: the link's current timestamp (CACurrentMediaTime timebase)
    ///   - targetTimestamp: predicted presentation time of the upcoming vsync
    func renderTick(now: Double, targetTimestamp: Double) {
        // ── Playout policy (hold queueLock for the shortest possible span) ──────
        // Deadline-based selection: present the newest frame whose targetWall falls
        // before the upcoming vsync (plus 25% slack for timer quantization). Older
        // due frames are stale — showing them would only add latency — so they're
        // dropped. If nothing is due yet, this tick draws nothing at all: the
        // previously presented drawable stays on glass for free, and the first
        // frames after stream start are naturally held until playoutDelay elapses
        // (no separate priming state needed).
        var selectedBuffer: CVPixelBuffer? = nil
        var selectedEnqueuedAt: Double = 0
        var selectedPTS: CMTime?
        var isStarved = false
        var lateDropCount = 0

        queueLock.lock()
        if frameQueue.isEmpty {
            // Empty queue at tick time is a stat, not stress: sub-fps content
            // legitimately drains the queue between frames. Real network/decode
            // lateness is detected at enqueue (late-arrival) where it can be
            // measured against the frame's own schedule.
            if lastRenderedBuffer != nil {
                isStarved = true
            }
        } else {
            let deadline = targetTimestamp + frameDuration * 0.25
            var dueCount = 0
            for frame in frameQueue {
                if frame.targetWall <= deadline { dueCount += 1 } else { break }
            }
            if dueCount > 0 {
                // Exactly two due means the older frame barely missed the previous
                // vsync (deadline boundary flip-flop). Present it anyway — the newer
                // frame goes out next tick and the servo trims the half-frame of
                // latency. Skipping it was a visible microstutter (content jump +
                // 16.7 ms present gap) once or twice a second. Three or more due is
                // a genuine backlog: skip to the newest, drop the stale ones.
                // Note: lateDrops deliberately do NOT touch lastStressTime. They are
                // presentation-side tick slips; a deeper arrival buffer cannot prevent
                // them, so they must not block buffer decay (observed: latency stuck
                // at 5 frames because 1-2 lateDrops/s kept resetting the decay timer).
                let takeIndex = dueCount >= 3 ? dueCount - 1 : 0
                lateDropCount = takeIndex
                let next = frameQueue[takeIndex]
                frameQueue.removeFirst(takeIndex + 1)
                selectedBuffer = next.pixelBuffer
                selectedEnqueuedAt = next.enqueuedAt
                selectedPTS = next.pts
            }
        }
        let currentDepth = frameQueue.count
        queueLock.unlock()
        // ── End playout policy ───────────────────────────────────────────────

        // Single consolidated stats call after lock release.
        let intervalMs = lastDrawTime > 0 ? (now - lastDrawTime) * 1000.0 : 0

        let isNewFrame = selectedBuffer != nil
        if let buffer = selectedBuffer {
            lastDrawTime = now
            let ageMs = selectedEnqueuedAt > 0 ? (now - selectedEnqueuedAt) * 1000.0 : 0
            stats?.recordRenderTick(queueDepth: currentDepth, lateDrops: lateDropCount,
                                    drawIntervalMs: intervalMs, frameAgeMs: ageMs, repeated: false)
            repeatedDrawsSincePresent = 0
            lastRenderedBuffer = buffer
        } else if isStarved {
            lastDrawTime = now
            stats?.recordRenderTick(queueDepth: currentDepth, lateDrops: 0,
                                    drawIntervalMs: intervalMs, frameAgeMs: 0, repeated: true)
            repeatedDrawsSincePresent += 1
            if repeatedDrawsSincePresent == 60 && repeatStallLogCount < 3 {
                repeatStallLogCount += 1
                StreamLog.log("[ChloroFrame][video] starved for 60 ticks depth=\(currentDepth)")
            }
        } else {
            // Nothing due yet (early frames still maturing, or tick ran ahead of the
            // stream). Not an underflow — record occupancy only, skip draw stats.
            stats?.recordRenderTick(queueDepth: currentDepth, lateDrops: 0,
                                    drawIntervalMs: nil, frameAgeMs: 0, repeated: false)
        }

        // Ticks with no new frame still re-render and re-present the previous buffer.
        // Skipping the present entirely made the window look idle to the compositor,
        // and ProMotion would downclock to 48 Hz — the next real frame then waited up
        // to ~21 ms for a vsync slot (observed as 20.8 ms draw intervals + late-drop
        // bursts). A repeat present is ~0.5 ms of GPU via the texture cache and keeps
        // the display link pinned at the stream rate.
        guard let pixelBuffer = selectedBuffer ?? lastRenderedBuffer, let cache = textureCache,
              let layer = metalLayer else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Texture format from pixel format (storage precision).
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isP010 = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let yFmt:  MTLPixelFormat = isP010 ? .r16Unorm  : .r8Unorm
        let uvFmt: MTLPixelFormat = isP010 ? .rg16Unorm : .rg8Unorm

        // Confirmed HDR: P010 is necessary but not sufficient. All three must be true:
        //   1. PQ (ST.2084) transfer function — HLG needs a different EOTF, not implemented here
        //   2. BT.2020 color primaries
        //   3. BT.2020 YCbCr matrix
        // VT propagates these from SPS/VPS HDR metadata; they're the same for every frame,
        // so the check runs once per pixel format and is cached afterwards.
        let isFrameHDR: Bool
        if let cached = cachedHDRForFormat, cached.format == pixelFormat {
            isFrameHDR = cached.isHDR
        } else {
            if isP010 {
                let tf = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
                let pr = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,   nil) as? String
                let mx = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,      nil) as? String
                isFrameHDR = tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                          && pr == (kCVImageBufferColorPrimaries_ITU_R_2020          as String)
                          && mx == (kCVImageBufferYCbCrMatrix_ITU_R_2020             as String)
            } else {
                isFrameHDR = false
            }
            cachedHDRForFormat = (pixelFormat, isFrameHDR)
        }

        // Update layer EDR mode when HDR-ness changes (effectively once per stream).
        // extendedLinearITUR_2020: declares the layer content is linear-light BT.2020;
        // macOS handles gamut conversion to the Mac display's native primaries (Display P3 etc).
        // Layer property mutation belongs on the main thread — we're on the render thread.
        if isFrameHDR != lastDetectedHDR {
            lastDetectedHDR = isFrameHDR
            DispatchQueue.main.async { [weak layer] in
                #if os(macOS)
                layer?.wantsExtendedDynamicRangeContent = isFrameHDR
                #endif
                layer?.colorspace = isFrameHDR ? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) : nil
            }
        }

        var yRef: CVMetalTexture?, uvRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, yFmt, w, h, 0, &yRef
        ) == kCVReturnSuccess, let yRef,
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, uvFmt, w / 2, h / 2, 1, &uvRef
        ) == kCVReturnSuccess, let uvRef else {
            if textureFailureLogCount < 3 {
                textureFailureLogCount += 1
                StreamLog.log("[ChloroFrame][video] texture creation failed fmt=\(isP010 ? "P010" : "NV12") size=\(w)x\(h)")
            }
            return
        }

        guard let yTex  = CVMetalTextureGetTexture(yRef),
              let uvTex = CVMetalTextureGetTexture(uvRef) else { return }

        // Acquire the drawable as late as possible: everything above needed no drawable,
        // so we never block on the drawable pool for ticks that end up drawing nothing.
        guard let drawable = layer.nextDrawable() else {
            if textureFailureLogCount < 3 {
                textureFailureLogCount += 1
                StreamLog.log("[ChloroFrame][video] nextDrawable returned nil")
            }
            return
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture     = drawable.texture
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(isFrameHDR ? pipelineStateHDR : pipelineStateSDR)
        enc.setFragmentTexture(yTex,  index: 0)
        enc.setFragmentTexture(uvTex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        commandBuffer.addCompletedHandler { _ in _ = yRef; _ = uvRef }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if isNewFrame && presentLogCount < 3 {
            presentLogCount += 1
            StreamLog.log("[ChloroFrame][video] present pts=\(selectedPTS?.value ?? -1) fmt=\(isP010 ? "P010" : "NV12") hdr=\(isFrameHDR) depth=\(currentDepth)")
        }
    }
}

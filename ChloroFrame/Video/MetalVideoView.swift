//
//  MetalVideoView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI
import AppKit
import Metal
import CoreMedia
import CoreVideo
import QuartzCore

/// A SwiftUI view that wraps a Metal-based video renderer
/// This provides ultra-low latency video display using the GPU
struct MetalVideoView: NSViewRepresentable {
    let renderer: MetalVideoRenderer
    var streamFps: Int = 120
    var inputHandler: InputHandler?
    var onDisconnect: (() -> Void)?
    var onToggleStats: (() -> Void)?

    func makeNSView(context: Context) -> InputCaptureMetalView {
        let view = InputCaptureMetalView()
        view.inputHandler = inputHandler
        view.onDisconnect = onDisconnect
        view.onToggleStats = onToggleStats
        view.streamFps = streamFps
        view.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: InputCaptureMetalView, context: Context) {
        nsView.renderer = renderer
        if nsView.inputHandler != nil && inputHandler == nil { nsView.releaseCursor() }
        nsView.inputHandler = inputHandler
        nsView.onDisconnect = onDisconnect
        nsView.onToggleStats = onToggleStats
        nsView.streamFps = streamFps
    }
}

// MARK: - Input-capturing Metal view

/// NSView hosting a CAMetalLayer; accepts keyboard/mouse events and forwards them to InputHandler.
/// Installed as first responder when it enters a window so events reach it immediately.
/// Cursor is locked (hidden + decoupled) on first click; Ctrl+⌥+⌘+M toggles it.
///
/// Rendering is driven by a CADisplayLink added to a dedicated userInteractive thread's
/// run loop — NOT the main thread. MTKView's built-in loop dispatched draw(in:) on main,
/// where it competed with HID-rate mouse events, the 8 ms input flush timer, and SwiftUI
/// updates; any main-thread hiccup ≥ one refresh interval showed up as a repeated frame
/// (microstutter). NSView.displayLink(target:selector:) tracks the view's current display
/// automatically, so screen moves/refresh-rate changes need no manual rebinding.
final class InputCaptureMetalView: NSView {

    var inputHandler: InputHandler?
    var onDisconnect: (() -> Void)?
    var onToggleStats: (() -> Void)?
    /// Stream FPS requested by the server. Caps the display link's frame-rate range so a
    /// 60 fps stream on a 120 Hz display ticks at 60 Hz instead of double-drawing.
    var streamFps: Int = 120 {
        didSet { if streamFps != oldValue { applyFrameRateRange() } }
    }
    var renderer: MetalVideoRenderer? {
        didSet {
            guard let renderer else { return }
            configureLayer(for: renderer)
        }
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?
    private var renderThread: Thread?
    // Read by the render thread each tick; written on main by start/stopRenderLoop.
    private let renderLoopActive = NSConditionLock(condition: 0)

    private var cursorLocked = false
    private var localMouseMonitor: Any?
    // True when appWillResignActive released a previously-locked cursor.
    // Used by appDidBecomeActive to restore the lock automatically so a brief
    // focus loss (system notification, HDR display config, Spotlight, etc.) doesn't
    // permanently break mouse input. Only set when the cursor was ALREADY locked —
    // a manual Ctrl+⌥+⌘+M release leaves this false so we don't re-lock on return.
    private var restoreCursorLockOnActivate = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // the display link presents; AppKit never redraws us
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.framebufferOnly = true
        layer.displaySyncEnabled = true     // Opt-G: vsync-locked presentation
        layer.maximumDrawableCount = 3
        return layer
    }

    private func configureLayer(for renderer: MetalVideoRenderer) {
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = renderer.drawablePixelFormat
        renderer.attach(layer: metalLayer)
    }

    // MARK: - Drawable size

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        if let scale = window?.backingScaleFactor, scale > 0 {
            metalLayer.contentsScale = scale
        }
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0, size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
        renderer?.updateDrawableSize(size)
    }

    // MARK: - Render loop (dedicated thread)

    private func startRenderLoop() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(renderTick(_:)))
        displayLink = link
        applyFrameRateRange()
        renderLoopActive.lock()
        renderLoopActive.unlock(withCondition: 1)

        let thread = Thread { [renderLoopActive] in
            link.add(to: .current, forMode: .default)
            // Spin the run loop until stopRenderLoop() flips the condition to 0.
            // The 0.1 s timeout bounds how long the flag check can be deferred when
            // the link is suspended (view hidden/occluded) and no sources fire.
            while renderLoopActive.condition == 1 {
                autoreleasepool {
                    _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
                }
            }
            // Invalidate on the thread that owns the run loop the link is attached to.
            link.invalidate()
        }
        thread.name = "chloroframe.render"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
    }

    private func stopRenderLoop() {
        guard displayLink != nil else { return }
        renderLoopActive.lock()
        renderLoopActive.unlock(withCondition: 0)
        displayLink = nil
        renderThread = nil
    }

    private func applyFrameRateRange() {
        guard let link = displayLink else { return }
        let screenMax = window?.screen?.maximumFramesPerSecond ?? 120
        let fps = Float(min(streamFps > 0 ? streamFps : 120, screenMax))
        // Pin the link to a FIXED rate. A permissive minimum let ProMotion downclock
        // to 48 Hz during skip-render stretches (sub-fps content), adding up to ~21 ms
        // of tick latency to the next real frame — observed as 20.8 ms draw intervals.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    @objc private func renderTick(_ link: CADisplayLink) {
        // Runs on the render thread. targetTimestamp is the predicted presentation
        // time of the upcoming vsync, in the CACurrentMediaTime() timebase.
        renderer?.renderTick(now: link.timestamp, targetTimestamp: link.targetTimestamp)
    }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            resetTrackingArea()
            applyBackingScale()
            startRenderLoop()
            autoCaptureCursor()
            NotificationCenter.default.addObserver(
                self, selector: #selector(appWillResignActive),
                name: NSApplication.willResignActiveNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification, object: nil
            )
        } else {
            stopRenderLoop()
            restoreCursorLockOnActivate = false
            releaseCursor()
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.willResignActiveNotification, object: nil
            )
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.didBecomeActiveNotification, object: nil
            )
        }
    }

    @objc private func appWillResignActive() {
        restoreCursorLockOnActivate = cursorLocked
        inputHandler?.releaseAll()
        releaseCursor()
    }

    @objc private func appDidBecomeActive() {
        guard restoreCursorLockOnActivate, window?.isKeyWindow == true else { return }
        restoreCursorLockOnActivate = false
        lockCursor()
    }

    // Capture the cursor as soon as the stream window becomes key, so the user does not have to
    // click to "sync" on launch. The view attaches a beat before the window finishes becoming
    // key, so poll a few runloop turns for key status, then lock. Gives up quietly if the window
    // never becomes key (e.g. launched in the background) — a click still locks then.
    private func autoCaptureCursor(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.cursorLocked else { return }
            if self.window?.isKeyWindow == true {
                self.lockCursor()
            } else if attempt < 20 {
                self.autoCaptureCursor(attempt: attempt + 1)
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            inputHandler?.releaseAll()
            releaseCursor()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetTrackingArea()
    }

    private func resetTrackingArea() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Cursor lock/unlock

    // We use CGAssociateMouseAndMouseCursorPosition(0) to decouple the cursor's screen
    // position from actual mouse movement. This keeps the cursor frozen inside our view
    // so fast moves can't escape the tracking area and cut off event delivery.
    //
    // Trade-off: with position decoupled, AppKit tracking areas stop firing mouseMoved
    // (they're position-based and the position never changes). We compensate by installing
    // a local event monitor that receives the underlying HID events directly.
    private func lockCursor() {
        guard !cursorLocked else { return }
        cursorLocked = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        warpCursorToCenter()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.inputHandler?.handleMouseMoved(event)
            return event
        }
    }

    func releaseCursor() {
        guard cursorLocked else { return }
        cursorLocked = false
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func warpCursorToCenter() {
        guard let window = window, let primaryScreen = NSScreen.screens.first else { return }
        let viewCenter  = NSPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(viewCenter, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        // AppKit global: origin at bottom-left of primary screen, Y increases upward.
        // CGWarpMouseCursorPosition: origin at top-left of primary screen, Y increases downward.
        let cgPoint = CGPoint(x: screenPoint.x,
                              y: primaryScreen.frame.height - screenPoint.y)
        CGWarpMouseCursorPosition(cgPoint)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Ctrl+Option+Command+Q: disconnect stream
        if event.keyCode == 12 && mods == [.control, .option, .command] {
            releaseCursor()
            onDisconnect?()
            return
        }
        // Ctrl+Option+Command+M: toggle cursor lock
        if event.keyCode == 46 && mods == [.control, .option, .command] {
            if cursorLocked { releaseCursor() } else { lockCursor() }
            return
        }
        // Ctrl+Option+Command+S: toggle stream stats HUD (keyCode 0x01 = S)
        if event.keyCode == 0x01 && mods == [.control, .option, .command] {
            onToggleStats?()
            return
        }
        // Ctrl+Option+Command+F: activate the fn-layer latch (10 s). fn itself is reserved by
        // macOS (Dictation/emoji), so F is the trigger. keyCode 0x03 = F.
        if event.keyCode == 0x03 && mods == [.control, .option, .command] {
            inputHandler?.activateFnLatch()
            return
        }
        // The remote OS handles its own key-repeat; don't send repeat events.
        guard !event.isARepeat else { return }
        inputHandler?.handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        inputHandler?.handleKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler?.handleFlagsChanged(event)
    }

    // MARK: - Mouse movement

    // When cursor is locked, CGAssociate(0) prevents tracking areas from firing.
    // The local monitor installed in lockCursor() handles all movement events in that state.
    // These overrides cover the unlocked state (tracking area + responder chain delivery).
    override func mouseMoved(with event: NSEvent) {
        guard !cursorLocked else { return }
        inputHandler?.handleMouseMoved(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !cursorLocked else { return }
        inputHandler?.handleMouseMoved(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !cursorLocked else { return }
        inputHandler?.handleMouseMoved(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard !cursorLocked else { return }
        inputHandler?.handleMouseMoved(event)
    }

    // MARK: - Mouse buttons

    override func mouseDown(with event: NSEvent) {
        if !cursorLocked { lockCursor() }
        inputHandler?.handleMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        inputHandler?.handleMouseUp(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        inputHandler?.handleMouseDown(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        inputHandler?.handleMouseUp(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        inputHandler?.handleMouseDown(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        inputHandler?.handleMouseUp(event)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        inputHandler?.handleScrollWheel(event)
    }
}

// MARK: - NSTextInputClient
//
// Minimal conformance so the OS can deliver IME-composed text, emoji, and other characters
// that can't be represented as VK codes. Regular key presses still go through the VK path
// in keyDown — this extension only fires when AppKit/IME calls insertText directly (e.g.,
// via the emoji picker, CJK input methods, or macOS spell-correction suggestions).
//
// We deliberately do NOT call interpretKeyEvents from keyDown, which avoids double-sending
// a VK code and a Unicode event for the same key press (which would cause duplicate characters
// on the remote). Dead-key compositions (e.g., Option+E then A = á) are a known gap;
// they'll send as two separate VK presses rather than a composed character.
extension InputCaptureMetalView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { return }
        guard !text.isEmpty else { return }
        inputHandler?.handleText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { }
    func unmarkText() { }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

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
        layer.wantsExtendedDynamicRangeContent = effectiveHDR
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
                layer?.wantsExtendedDynamicRangeContent = isFrameHDR
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

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
    var onShowControls: (() -> Void)?

    func makeNSView(context: Context) -> InputCaptureMetalView {
        let view = InputCaptureMetalView()
        view.inputHandler = inputHandler
        view.onDisconnect = onDisconnect
        view.onToggleStats = onToggleStats
        view.onShowControls = onShowControls
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
        nsView.onShowControls = onShowControls
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
    var onShowControls: (() -> Void)?
    // Discovery gesture: holding ⌃⌥⌘ alone (no other key) for 2 s reveals the controls overlay.
    // Scheduled when the trio completes; cancelled if the trio breaks or any key is pressed
    // (a key press means the user is invoking a hotkey, not asking for the list).
    private var controlsHoldWork: DispatchWorkItem?
    private var trioComplete = false
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
        // Any key press while waiting means the trio is being used as a hotkey prefix,
        // not as the "show me the controls" gesture. Cancel the discovery timer.
        cancelControlsHold()
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

        // Track the ⌃⌥⌘ trio for the discovery overlay. Exactly the three, nothing else.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let nowComplete = mods == [.control, .option, .command]
        if nowComplete && !trioComplete {
            scheduleControlsHold()
        } else if !nowComplete {
            cancelControlsHold()
        }
        trioComplete = nowComplete
    }

    private func scheduleControlsHold() {
        controlsHoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.trioComplete else { return }
            self.onShowControls?()
        }
        controlsHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func cancelControlsHold() {
        controlsHoldWork?.cancel()
        controlsHoldWork = nil
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

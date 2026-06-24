//
//  TVMetalVideoView.swift
//  ChloroFrameTV
//
//  tvOS host for the shared MetalVideoRenderer (Phase 5). A UIView backed by a
//  CAMetalLayer, mirroring the macOS InputCaptureMetalView but without any input
//  capture. This view owns the CADisplayLink and calls the renderer's
//  renderTick(now:targetTimestamp:) each vsync.
//
//  MVP runs the display link on the main run loop. The macOS path uses a dedicated
//  render thread to avoid microstutter; if tvOS shows the same, move it off-main
//  later. The renderer's internal queueLock already makes enqueue (decode thread)
//  and renderTick (this thread) safe to run concurrently.
//

import SwiftUI
import UIKit
import QuartzCore
import Metal
import GameController

struct TVMetalVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    var streamFps: Int

    func makeUIView(context: Context) -> TVMetalUIView {
        let view = TVMetalUIView()
        view.renderer = renderer
        view.streamFps = streamFps
        return view
    }

    func updateUIView(_ uiView: TVMetalUIView, context: Context) {
        uiView.streamFps = streamFps
    }
}

final class TVMetalUIView: UIView {
    var renderer: MetalVideoRenderer?
    var streamFps: Int = 60 { didSet { applyFrameRateRange() } }

    private var displayLink: CADisplayLink?

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        guard let renderer else { return }
        metalLayer.pixelFormat = renderer.drawablePixelFormat
        renderer.attach(layer: metalLayer)
        updateDrawableSize()

        let link = CADisplayLink(target: self, selector: #selector(renderTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        applyFrameRateRange()
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = size
        renderer?.updateDrawableSize(size)
    }

    private func applyFrameRateRange() {
        guard let link = displayLink else { return }
        let screenMax = window?.screen.maximumFramesPerSecond ?? 60
        let fps = Float(min(streamFps > 0 ? streamFps : 60, screenMax))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }

    @objc private func renderTick(_ link: CADisplayLink) {
        renderer?.renderTick(now: link.timestamp, targetTimestamp: link.targetTimestamp)
    }
}

// MARK: - Game-controller-aware streaming surface

/// Hosts the Metal video surface inside a GCEventViewController with focus interaction turned
/// OFF, so a game controller drives the *host* (via our translator's GCController polling)
/// instead of the tvOS focus engine. Without this, tvOS treats the controller as a UI navigation
/// device — Circle/B pops the view, the dpad moves focus, etc. The Menu button (which would
/// otherwise dismiss) is captured here and routed to `onExit` so there's still a way out.
///
/// Note: the controller's Home/PS/Xbox (Guide) button is system-reserved on tvOS and always opens
/// Control Center; an app cannot capture it. So Guide is intentionally not used for host input.
struct TVStreamSurface: UIViewControllerRepresentable {
    let renderer: MetalVideoRenderer
    var streamFps: Int
    var transport: StreamTransport?
    var onExit: () -> Void
    var onMenu: () -> Void
    /// When true (the nav overlay is up), focus interaction is re-enabled so the remote can drive
    /// the overlay, and the remote-as-mouse handling pauses.
    var overlayActive: Bool

    func makeUIViewController(context: Context) -> TVStreamViewController {
        let vc = TVStreamViewController()
        vc.metalView.renderer = renderer
        vc.metalView.streamFps = streamFps
        vc.remoteInput = TVRemoteInput(transport: transport)
        vc.onExit = onExit
        vc.onMenu = onMenu
        return vc
    }

    func updateUIViewController(_ vc: TVStreamViewController, context: Context) {
        vc.metalView.streamFps = streamFps
        vc.onExit = onExit
        vc.onMenu = onMenu
        vc.setOverlayActive(overlayActive)
    }
}

/// Siri Remote → host mouse mapping during a stream (a physical game controller, when present,
/// still passes through as a gamepad via TVControllerTranslator):
///   - touch surface swipe  → relative pointer move (trackpad feel, with acceleration)
///   - center click         → left click; long-press → right click
///   - edge clicks (arrows) → scroll (repeat while held)
///   - play/pause           → disconnect
///   - menu                 → exit (becomes the nav overlay in a later step)
///
/// UIPress types are physical clicks; the pan gesture is finger movement. That split is what lets
/// "swipe = pointer" and "edge-click = scroll" coexist (GameController's analog dpad can't separate
/// them). Focus interaction stays off so none of this drives the tvOS focus engine.
final class TVStreamViewController: GCEventViewController {
    let metalView = TVMetalUIView()
    var onExit: (() -> Void)?
    var onMenu: (() -> Void)?
    var remoteInput: TVRemoteInput?
    private var inputPaused = false             // overlay up: hand input to the focus engine

    /// Re-enable focus interaction so the remote can navigate the overlay, and pause the
    /// mouse mapping. Off again restores the host-mouse behavior.
    func setOverlayActive(_ active: Bool) {
        inputPaused = active
        controllerUserInteractionEnabled = active
        if active {
            selectTimer?.invalidate(); selectTimer = nil; selectDown = false
            scrollTimers.values.forEach { $0.invalidate() }; scrollTimers.removeAll()
            remoteInput?.releaseAll()
        }
    }

    private var selectTimer: Timer?
    private var selectHandled = false           // true once a long-press fired a right click
    private var selectDown = false              // a center click is currently held
    private var panTracking = false             // this swipe has passed the start threshold
    private var scrollTimers: [UIPress.PressType: Timer] = [:]

    private let longPressSeconds = 0.45
    private let scrollRepeat = 0.05
    private let scrollStep: Int16 = 28
    // Pointer feel. pointerSpeed scales finger travel -> pointer travel; moveThreshold is the
    // minimum swipe before tracking starts so a tap's jitter doesn't move the pointer.
    private let pointerSpeed: CGFloat = 0.34
    private let moveThreshold: CGFloat = 14

    override func viewDidLoad() {
        super.viewDidLoad()
        // Controller input belongs to the host, not the tvOS focus engine.
        controllerUserInteractionEnabled = false
        view.backgroundColor = .black
        metalView.frame = view.bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(metalView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        selectTimer?.invalidate()
        scrollTimers.values.forEach { $0.invalidate() }
        scrollTimers.removeAll()
        remoteInput?.releaseAll()
    }

    // MARK: - Pointer

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        if inputPaused { return }
        switch gr.state {
        case .began:
            gr.setTranslation(.zero, in: view)
            panTracking = false
        case .changed:
            // Freeze while a click is held: the finger always drifts a little during a press
            // (and a long-press), and that drift was dragging the pointer off small targets.
            if selectDown { gr.setTranslation(.zero, in: view); return }
            let t = gr.translation(in: view)
            // Require a small deliberate swipe before tracking starts, so a tap (which jitters
            // slightly) doesn't move the pointer at all.
            if !panTracking {
                if hypot(t.x, t.y) < moveThreshold { return }
                panTracking = true
                gr.setTranslation(.zero, in: view)   // discard the threshold travel (no jump)
                return
            }
            let v = gr.velocity(in: view)
            // Gentle acceleration: slow moves stay precise, fast swipes still cross the screen.
            let accel = 1.0 + min(2.0, hypot(v.x, v.y) / 1600.0)
            remoteInput?.moveRelative(dx: t.x * pointerSpeed * accel, dy: t.y * pointerSpeed * accel)
            gr.setTranslation(.zero, in: view)
        default:
            panTracking = false
        }
    }

    // MARK: - Buttons (physical clicks)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if inputPaused { super.pressesBegan(presses, with: event); return }
        var handled = true
        for press in presses {
            switch press.type {
            case .menu:        onMenu?()       // open the nav overlay
            case .playPause:   onExit?()       // disconnect
            case .select:      beginSelect()
            case .upArrow, .downArrow, .leftArrow, .rightArrow:
                beginScroll(press.type)
            default:
                handled = false
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if inputPaused { super.pressesEnded(presses, with: event); return }
        for press in presses {
            switch press.type {
            case .select: endSelect()
            case .upArrow, .downArrow, .leftArrow, .rightArrow: endScroll(press.type)
            default: break
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if inputPaused { super.pressesCancelled(presses, with: event); return }
        for press in presses {
            if press.type == .select { endSelect() }
            else { endScroll(press.type) }
        }
        super.pressesCancelled(presses, with: event)
    }

    private func beginSelect() {
        selectHandled = false
        selectDown = true
        selectTimer?.invalidate()
        selectTimer = Timer.scheduledTimer(withTimeInterval: longPressSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.selectHandled = true            // long hold → right click
            self.remoteInput?.click(TVRemoteInput.rightButton)
        }
    }

    private func endSelect() {
        selectTimer?.invalidate(); selectTimer = nil
        selectDown = false
        if !selectHandled {                       // released before the hold threshold → left click
            remoteInput?.click(TVRemoteInput.leftButton)
        }
        selectHandled = false
    }

    private func beginScroll(_ type: UIPress.PressType) {
        scrollTimers[type]?.invalidate()
        sendScroll(type)                          // immediate step on press
        scrollTimers[type] = Timer.scheduledTimer(withTimeInterval: scrollRepeat, repeats: true) { [weak self] _ in
            self?.sendScroll(type)
        }
    }

    private func endScroll(_ type: UIPress.PressType) {
        scrollTimers[type]?.invalidate()
        scrollTimers[type] = nil
    }

    private func sendScroll(_ type: UIPress.PressType) {
        switch type {
        case .upArrow:    remoteInput?.scrollVertical(scrollStep)
        case .downArrow:  remoteInput?.scrollVertical(-scrollStep)
        case .leftArrow:  remoteInput?.scrollHorizontal(-scrollStep)
        case .rightArrow: remoteInput?.scrollHorizontal(scrollStep)
        default: break
        }
    }
}

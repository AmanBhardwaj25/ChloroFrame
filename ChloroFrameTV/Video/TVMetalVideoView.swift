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
    var onExit: () -> Void

    func makeUIViewController(context: Context) -> TVStreamViewController {
        let vc = TVStreamViewController()
        vc.metalView.renderer = renderer
        vc.metalView.streamFps = streamFps
        vc.onExit = onExit
        return vc
    }

    func updateUIViewController(_ vc: TVStreamViewController, context: Context) {
        vc.metalView.streamFps = streamFps
        vc.onExit = onExit
    }
}

final class TVStreamViewController: GCEventViewController {
    let metalView = TVMetalUIView()
    var onExit: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Controller input belongs to the host, not the tvOS focus engine.
        controllerUserInteractionEnabled = false
        view.backgroundColor = .black
        metalView.frame = view.bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(metalView)
    }

    // With focus interaction off, the Menu button is delivered here instead of dismissing the
    // view automatically. Use it as the explicit exit.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onExit?()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }
}

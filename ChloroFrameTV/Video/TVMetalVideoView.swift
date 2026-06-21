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

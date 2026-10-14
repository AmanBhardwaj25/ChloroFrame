//
//  PlanarVideoFrame.swift
//  ChloroFrame
//
//  A decoded PyroWave frame: three single-channel textures (Y, Cb, Cr) plus the
//  parameters the renderer needs to turn them into RGB. Frames come from a
//  PlanarFramePool and hand their textures back on deinit, so whoever holds a
//  frame (the render queue, a GPU completion handler) keeps the textures out of
//  the pool.
//

import Foundation
import Metal

nonisolated final class PlanarVideoFrame: @unchecked Sendable {
    let y: MTLTexture
    let cb: MTLTexture
    let cr: MTLTexture
    let color: PlanarColorParams

    private let pool: PlanarFramePool

    fileprivate init(y: MTLTexture, cb: MTLTexture, cr: MTLTexture,
                     color: PlanarColorParams, pool: PlanarFramePool) {
        self.y = y
        self.cb = cb
        self.cr = cr
        self.color = color
        self.pool = pool
    }

    deinit { pool.recycle(y: y, cb: cb, cr: cr) }
}

nonisolated final class PlanarFramePool: @unchecked Sendable {

    let device: MTLDevice
    let width: Int
    let height: Int
    let chroma444: Bool
    let bitDepth: Int
    let maxFrames: Int

    /// Stamped on every frame handed out; set from what the session negotiated and updated by
    /// the host's HDR mode message (D9). Frames already handed out keep the value they got.
    var color: PlanarColorParams {
        get { lock.withLock { currentColor } }
        set { lock.withLock { currentColor = newValue } }
    }
    private var currentColor: PlanarColorParams

    private let storageMode: MTLStorageMode
    private let lock = NSLock()
    private var free: [(y: MTLTexture, cb: MTLTexture, cr: MTLTexture)] = []
    private var inUse = 0

    /// - Parameter storageMode: `.private` for streaming; tests pass `.shared` to read back.
    /// - Parameter color: defaults to BT.709 limited SDR, the stream ChloroFrame asks for (Q3).
    init(device: MTLDevice, width: Int, height: Int, chroma444: Bool, bitDepth: Int,
         maxFrames: Int = 16, storageMode: MTLStorageMode = .private,
         color: PlanarColorParams? = nil) {
        self.device = device
        self.width = width
        self.height = height
        self.chroma444 = chroma444
        self.bitDepth = bitDepth
        self.maxFrames = maxFrames
        self.storageMode = storageMode
        self.currentColor = color ?? PlanarColorParams(bitDepth: bitDepth, fullRange: false,
                                                       matrix: .bt709, transfer: .sdr)
    }

    /// Frames currently handed out and not yet released.
    var framesInUse: Int { lock.withLock { inUse } }

    /// Returns nil when `maxFrames` are all in use; the caller drops the frame.
    func acquire() -> PlanarVideoFrame? {
        // Reserve a slot under the lock; textures are allocated outside it.
        var reserved = false
        var stamp = PlanarColorParams(bitDepth: bitDepth, fullRange: false)
        let reused: (y: MTLTexture, cb: MTLTexture, cr: MTLTexture)? = lock.withLock {
            guard inUse < maxFrames else { return nil }
            inUse += 1
            reserved = true
            stamp = currentColor
            return free.popLast()
        }
        guard reserved else { return nil }

        let planes: (y: MTLTexture, cb: MTLTexture, cr: MTLTexture)
        if let reused {
            planes = reused
        } else if let made = makeTextures() {
            planes = made
        } else {
            lock.withLock { inUse -= 1 }
            return nil
        }
        return PlanarVideoFrame(y: planes.y, cb: planes.cb, cr: planes.cr,
                                color: stamp, pool: self)
    }

    fileprivate func recycle(y: MTLTexture, cb: MTLTexture, cr: MTLTexture) {
        lock.withLock {
            inUse -= 1
            free.append((y, cb, cr))
        }
    }

    private func makeTextures() -> (y: MTLTexture, cb: MTLTexture, cr: MTLTexture)? {
        let format: MTLPixelFormat = bitDepth > 8 ? .r16Unorm : .r8Unorm
        let chromaWidth = chroma444 ? width : width / 2
        let chromaHeight = chroma444 ? height : height / 2

        func texture(_ w: Int, _ h: Int, _ label: String) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                width: w, height: h,
                                                                mipmapped: false)
            // The decoder requires shaderWrite (validate_plane in pyrowave_decoder.mm).
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = storageMode
            let t = device.makeTexture(descriptor: desc)
            t?.label = label
            return t
        }

        guard let y = texture(width, height, "PyroWave Y"),
              let cb = texture(chromaWidth, chromaHeight, "PyroWave Cb"),
              let cr = texture(chromaWidth, chromaHeight, "PyroWave Cr") else { return nil }
        return (y, cb, cr)
    }
}

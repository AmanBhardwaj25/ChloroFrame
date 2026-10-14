//
//  PlanarColorParams.swift
//  ChloroFrame
//
//  How to turn the three planes of a PlanarVideoFrame into RGB: sample range,
//  YCbCr matrix and transfer function, plus the fragment-shader uniform block
//  derived from them.
//
//  PyroWave planes hold normalized code values, `code / (2^N - 1)` (see the
//  protocol doc, "Decoding"). That differs from P010, where the 10-bit sample is
//  MSB-aligned in 16 bits (about `code / 1024`), so none of the HDR shader
//  constants apply here.
//

import Foundation
import simd

nonisolated enum PlanarMatrix: UInt8, Equatable {
    case bt601
    case bt709
    case bt2020
}

nonisolated enum PlanarTransfer: UInt8, Equatable {
    /// Gamma-encoded SDR; the shader outputs the converted R'G'B' as is.
    case sdr
    /// SMPTE ST 2084; the shader linearizes with the PQ EOTF and outputs EDR.
    case pq
}

/// Byte-identical to `PlanarColorUniforms` in Shaders.metal (80 bytes, all float4).
/// Field order and types must not change without changing the shader.
nonisolated struct PlanarShaderUniforms: Equatable {
    /// x: Y scale, y: Cb scale, z: Cr scale. Applied as `sample * scale + bias`.
    var scale: SIMD4<Float>
    /// x: Y bias, y: Cb bias, z: Cr bias.
    var bias: SIMD4<Float>
    /// Rows of the Y'CbCr to R'G'B' matrix (xyz used), Cb/Cr centered on 0.
    var rowR: SIMD4<Float>
    var rowG: SIMD4<Float>
    var rowB: SIMD4<Float>
}

nonisolated struct PlanarColorParams: Equatable {
    var bitDepth: Int
    var fullRange: Bool
    var matrix: PlanarMatrix
    var transfer: PlanarTransfer

    /// Defaults are BT.709 limited-range SDR: what the host is asked for with
    /// `encoderCscMode = 2` (decision Q3) and what the NV12 shader assumes.
    init(bitDepth: Int, fullRange: Bool,
         matrix: PlanarMatrix = .bt709, transfer: PlanarTransfer = .sdr) {
        self.bitDepth = bitDepth
        self.fullRange = fullRange
        self.matrix = matrix
        self.transfer = transfer
    }

    var isPQ: Bool { transfer == .pq }

    /// The color setup that follows from the `encoderCscMode` the client announced, using the
    /// host's own reading of it (vibeshine `video_colorspace.cpp`): bit 0 is full range, and
    /// `mode >> 1` selects BT.601, BT.709 or BT.2020. An HDR stream is BT.2020 with PQ whatever
    /// the matrix bits say. Modes outside 0...5 fall back to BT.709 like the host does.
    static func forEncoderCscMode(_ mode: Int, bitDepth: Int, hdr: Bool) -> PlanarColorParams {
        let matrix: PlanarMatrix
        switch mode >> 1 {
        case 0:  matrix = .bt601
        case 2:  matrix = .bt2020
        default: matrix = .bt709
        }
        return PlanarColorParams(bitDepth: bitDepth,
                                 fullRange: mode & 1 != 0,
                                 matrix: hdr ? .bt2020 : matrix,
                                 transfer: hdr ? .pq : .sdr)
    }

    // MARK: Range

    /// Normalized value of the largest code, `2^N - 1`.
    private var maxCode: Float { Float((1 << bitDepth) - 1) }

    /// Per-plane `(scale, bias)` such that `sample * scale + bias` gives Y' in
    /// [0, 1] (luma) or C centered on 0 in about [-0.5, 0.5] (chroma).
    ///
    /// With `M = 2^N - 1` and `k = 2^(N-8)`:
    ///   limited: Y' = (s*M - 16k) / (219k), C = (s*M - 128k) / (224k)
    ///   full:    Y' = s,                    C = s - 2^(N-1) / M
    var lumaScaleBias: (scale: Float, bias: Float) {
        if fullRange { return (1, 0) }
        let k = Float(1 << (bitDepth - 8))
        return (maxCode / (219 * k), -16 * k / (219 * k))
    }

    var chromaScaleBias: (scale: Float, bias: Float) {
        if fullRange { return (1, -Float(1 << (bitDepth - 1)) / maxCode) }
        let k = Float(1 << (bitDepth - 8))
        return (maxCode / (224 * k), -128 * k / (224 * k))
    }

    // MARK: Matrix

    /// Rows of Y'CbCr (Cb, Cr centered on 0) to R'G'B'.
    var matrixRows: (r: SIMD3<Float>, g: SIMD3<Float>, b: SIMD3<Float>) {
        switch matrix {
        case .bt601:
            return (SIMD3(1, 0, 1.402),
                    SIMD3(1, -0.344136, -0.714136),
                    SIMD3(1, 1.772, 0))
        case .bt709:
            return (SIMD3(1, 0, 1.5748),
                    SIMD3(1, -0.187324, -0.468124),
                    SIMD3(1, 1.8556, 0))
        case .bt2020:
            return (SIMD3(1, 0, 1.4746),
                    SIMD3(1, -0.164553, -0.571353),
                    SIMD3(1, 1.8814, 0))
        }
    }

    // MARK: Shader uniform

    var shaderUniforms: PlanarShaderUniforms {
        let l = lumaScaleBias
        let c = chromaScaleBias
        let m = matrixRows
        return PlanarShaderUniforms(
            scale: SIMD4(l.scale, c.scale, c.scale, 0),
            bias: SIMD4(l.bias, c.bias, c.bias, 0),
            rowR: SIMD4(m.r, 0),
            rowG: SIMD4(m.g, 0),
            rowB: SIMD4(m.b, 0))
    }

    // MARK: CPU reference (tests)

    /// Mirrors the shader math on the CPU: normalized samples in, unclamped
    /// R'G'B' out (before the SDR clamp or the PQ EOTF). Only for tests.
    func rgb(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        let u = shaderUniforms
        let ycc = SIMD3<Float>(y * u.scale.x + u.bias.x,
                               cb * u.scale.y + u.bias.y,
                               cr * u.scale.z + u.bias.z)
        return SIMD3(simd_dot(SIMD3(u.rowR.x, u.rowR.y, u.rowR.z), ycc),
                     simd_dot(SIMD3(u.rowG.x, u.rowG.y, u.rowG.z), ycc),
                     simd_dot(SIMD3(u.rowB.x, u.rowB.y, u.rowB.z), ycc))
    }

    /// Same as `rgb(y:cb:cr:)` for integer code values at this bit depth.
    func rgb(yCode: Int, cbCode: Int, crCode: Int) -> SIMD3<Float> {
        rgb(y: Float(yCode) / maxCode, cb: Float(cbCode) / maxCode, cr: Float(crCode) / maxCode)
    }
}

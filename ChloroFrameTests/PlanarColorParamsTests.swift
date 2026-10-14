//
//  PlanarColorParamsTests.swift
//  ChloroFrameTests
//
//  CPU-only checks of the scale/bias and matrix math that the planar fragment
//  shaders apply. The shaders themselves are not exercised here; they are not
//  verified until a host feeds the planar path (D6).
//

import XCTest
import Metal
import simd
@testable import ChloroFrame

final class PlanarColorParamsTests: XCTestCase {

    private func limited8(_ m: PlanarMatrix = .bt709) -> PlanarColorParams {
        PlanarColorParams(bitDepth: 8, fullRange: false, matrix: m, transfer: .sdr)
    }

    // MARK: Range

    func testLimited8BitLumaEndpoints() {
        let p = limited8()
        // Neutral chroma so only luma moves; every channel equals Y'.
        XCTAssertEqual(p.rgb(yCode: 16, cbCode: 128, crCode: 128).x, 0.0, accuracy: 1e-4)
        XCTAssertEqual(p.rgb(yCode: 235, cbCode: 128, crCode: 128).x, 1.0, accuracy: 1e-4)
    }

    func testLimited8BitNeutralChromaIsGray() {
        let p = limited8()
        for y in [16, 60, 126, 180, 235] {
            let c = p.rgb(yCode: y, cbCode: 128, crCode: 128)
            XCTAssertEqual(c.x, c.y, accuracy: 1e-4, "Y=\(y)")
            XCTAssertEqual(c.y, c.z, accuracy: 1e-4, "Y=\(y)")
        }
    }

    func testLimited8BitChromaEndpointsAreSymmetric() {
        let p = limited8()
        XCTAssertEqual(p.chromaScaleBias.scale * (16.0 / 255.0) + p.chromaScaleBias.bias, -0.5, accuracy: 1e-4)
        XCTAssertEqual(p.chromaScaleBias.scale * (240.0 / 255.0) + p.chromaScaleBias.bias, 0.5, accuracy: 1e-4)
    }

    func testLimited10BitLumaEndpoints() {
        let p = PlanarColorParams(bitDepth: 10, fullRange: false)
        XCTAssertEqual(p.rgb(yCode: 64, cbCode: 512, crCode: 512).x, 0.0, accuracy: 1e-4)
        XCTAssertEqual(p.rgb(yCode: 940, cbCode: 512, crCode: 512).x, 1.0, accuracy: 1e-4)
    }

    func testLimited10BitChromaCenterIsZero() {
        let p = PlanarColorParams(bitDepth: 10, fullRange: false)
        let c = p.chromaScaleBias
        XCTAssertEqual(c.scale * (512.0 / 1023.0) + c.bias, 0.0, accuracy: 1e-4)
        XCTAssertEqual(c.scale * (64.0 / 1023.0) + c.bias, -0.5, accuracy: 1e-4)
        XCTAssertEqual(c.scale * (960.0 / 1023.0) + c.bias, 0.5, accuracy: 1e-4)
    }

    func testFull8BitLumaEndpoints() {
        let p = PlanarColorParams(bitDepth: 8, fullRange: true)
        XCTAssertEqual(p.rgb(yCode: 0, cbCode: 128, crCode: 128).x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(p.rgb(yCode: 255, cbCode: 128, crCode: 128).x, 1.0, accuracy: 1e-3)
    }

    func testFull8BitChromaCenterIsNearZero() {
        // Chroma center is 2^(N-1)/M = 128/255, so code 128 maps to exactly 0.
        let p = PlanarColorParams(bitDepth: 8, fullRange: true)
        let c = p.chromaScaleBias
        XCTAssertEqual(c.scale * (128.0 / 255.0) + c.bias, 0.0, accuracy: 1e-6)
    }

    func testLumaScaleBiasIsOneFMAForLimitedRange() {
        // 8-bit limited: Y' = s * (255/219) - 16/219.
        let l = limited8().lumaScaleBias
        XCTAssertEqual(l.scale, 255.0 / 219.0, accuracy: 1e-5)
        XCTAssertEqual(l.bias, -16.0 / 219.0, accuracy: 1e-5)
    }

    // MARK: Matrix

    func testBT709LimitedRed() {
        let c = limited8(.bt709).rgb(yCode: 63, cbCode: 102, crCode: 240)
        XCTAssertEqual(c.x, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(c.z, 0.0, accuracy: 0.01)
    }

    func testBT601LimitedRed() {
        // BT.601 limited red is (81, 90, 240).
        let c = limited8(.bt601).rgb(yCode: 81, cbCode: 90, crCode: 240)
        XCTAssertEqual(c.x, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(c.z, 0.0, accuracy: 0.01)
    }

    func testBT2020LimitedRed() {
        // BT.2020 limited red is (74, 97, 240).
        let c = limited8(.bt2020).rgb(yCode: 74, cbCode: 97, crCode: 240)
        XCTAssertEqual(c.x, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(c.z, 0.0, accuracy: 0.01)
    }

    func testMatrixRowsHaveUnitLumaAndNoCrossChromaTerms() {
        for m in [PlanarMatrix.bt601, .bt709, .bt2020] {
            let rows = limited8(m).matrixRows
            XCTAssertEqual(rows.r.x, 1); XCTAssertEqual(rows.g.x, 1); XCTAssertEqual(rows.b.x, 1)
            XCTAssertEqual(rows.r.y, 0); XCTAssertEqual(rows.b.z, 0)
        }
    }

    // MARK: Uniform block

    func testShaderUniformLayoutMatchesMSL() {
        // PlanarColorUniforms in Shaders.metal is five float4 members.
        XCTAssertEqual(MemoryLayout<PlanarShaderUniforms>.stride, 80)
        XCTAssertEqual(MemoryLayout<PlanarShaderUniforms>.size, 80)
        XCTAssertEqual(MemoryLayout<PlanarShaderUniforms>.alignment, 16)
    }

    func testShaderUniformsCarryScaleBiasAndRows() {
        let p = limited8(.bt709)
        let u = p.shaderUniforms
        XCTAssertEqual(u.scale.x, p.lumaScaleBias.scale)
        XCTAssertEqual(u.bias.x, p.lumaScaleBias.bias)
        XCTAssertEqual(u.scale.y, p.chromaScaleBias.scale)
        XCTAssertEqual(u.scale.z, p.chromaScaleBias.scale)
        XCTAssertEqual(u.rowR.z, 1.5748)
        XCTAssertEqual(u.rowB.y, 1.8556)
    }

    func testDefaultsAreBT709LimitedSDR() {
        let p = PlanarColorParams(bitDepth: 8, fullRange: false)
        XCTAssertEqual(p.matrix, .bt709)
        XCTAssertEqual(p.transfer, .sdr)
        XCTAssertFalse(p.isPQ)
        XCTAssertTrue(PlanarColorParams(bitDepth: 10, fullRange: false, matrix: .bt2020, transfer: .pq).isPQ)
    }

    // MARK: Pipelines

    func testPlanarPipelinesBuildFromAppLibrary() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalVideoRenderer.self))
        for name in ["fragmentShaderPlanarSDR", "fragmentShaderPlanarPQ"] {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertexShader")
            desc.fragmentFunction = try XCTUnwrap(library.makeFunction(name: name), name)
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: desc), name)
        }
    }
}

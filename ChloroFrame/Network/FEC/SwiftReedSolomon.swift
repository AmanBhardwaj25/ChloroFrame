//
//  SwiftReedSolomon.swift
//  ChloroFrame
//
//  Pure Swift GF(2^8) Reed-Solomon, polynomial 285.
//  Direct translation of the OBLAS_TINY (scalar) path in nanors by
//  Joseph Calderon (https://github.com/sleepybishop/nanors), MIT License.
//  See nanors_impl.c for the full license notice.
//  Used when useSwiftFEC = true in Settings.

import Foundation

final class SwiftReedSolomon: ReedSolomonCoder {
    private let ds: Int   // data shards
    private let ps: Int   // parity shards
    // Cauchy parity matrix, flat row-major [ps × ds].
    // p[j*ds + i] = GF.inv[(ps + i) ^ j]
    private let p: [UInt8]

    init?(dataShards: Int, parityShards: Int) {
        guard dataShards > 0, parityShards > 0,
              dataShards + parityShards <= 255 else { return nil }
        ds = dataShards
        ps = parityShards
        var matrix = [UInt8](repeating: 0, count: parityShards * dataShards)
        for j in 0..<parityShards {
            for i in 0..<dataShards {
                matrix[j * dataShards + i] = GF.inv[(parityShards + i) ^ j]
            }
        }
        p = matrix
    }

    func decode(shards: inout [[UInt8]], marks: [Bool], blockSize: Int) -> Bool {
        // Collect erased data shard indices.
        var erasures = [Int]()
        for i in 0..<ds {
            if marks[i] { erasures.append(i) }
        }
        let W = erasures.count
        guard W > 0 else { return true }
        guard W <= ps else { return false }
        let V0 = ds - W   // count of present data shards

        // Build colperm: present data shards first (V0 of them), then erased.
        var colperm = [Int](repeating: 0, count: ds)
        var ci = 0
        for j in 0..<ds { if !marks[j] { colperm[ci] = j; ci += 1 } }
        for i in 0..<W   { colperm[V0 + i] = erasures[i] }

        // Build rowperm: for each erasure pick an available parity shard,
        // then copy that parity shard's content into the erased data slot.
        var rowperm = [Int](repeating: 0, count: W)
        var j = ds
        for i in 0..<W {
            while j < ds + ps && marks[j] { j += 1 }
            guard j < ds + ps else { return false }
            rowperm[i] = j - ds
            // Copy parity content into erased slot (decoded over the loop below).
            shards[erasures[i]] = shards[j]
            j += 1
        }

        // Work buffer W×W + W extra bytes to absorb the scal spill at x = W-1.
        var wrk = [UInt8](repeating: 0, count: W * W + W)

        // Step 1: Extract W×W sub-matrix from parity matrix.
        // wrk[i*W + j] = p[rowperm[i]*ds + colperm[V0+j]]
        for i in 0..<W {
            let dr = rowperm[i] * ds
            for j2 in 0..<W {
                wrk[i * W + j2] = p[dr + colperm[V0 + j2]]
            }
        }

        // Step 2: Subtract present-data contributions from the parity content
        // that was copied into each erased slot.
        for gap in 0..<W {
            let dr = rowperm[gap] * ds
            for row in 0..<V0 {
                let u = p[dr + colperm[row]]
                guard u != 0 else { continue }
                axpy(dst: &shards[colperm[V0 + gap]], src: shards[colperm[row]],
                     scalar: u, count: blockSize)
            }
        }

        // Step 3: Forward (lower-triangular) Gaussian elimination.
        for x in 0..<W {
            let u = GF.inv[Int(wrk[x * W + x])]
            // Scale row x starting from diagonal (W elements, spills W-1 bytes beyond W*W —
            // absorbed by the extra W bytes in wrk).
            wrkScal(&wrk, start: x * W + x, scalar: u, count: W)
            sShardScal(&shards[colperm[V0 + x]], scalar: u, count: blockSize)
            for row in (x + 1)..<W {
                let u2 = wrk[row * W + x]
                guard u2 != 0 else { continue }
                wrkAxpy(&wrk, dstRow: row * W, srcRow: x * W, scalar: u2, count: W)
                axpy(dst: &shards[colperm[V0 + row]], src: shards[colperm[V0 + x]],
                     scalar: u2, count: blockSize)
            }
        }

        // Step 4: Back substitution (upper-triangular elimination).
        for x in stride(from: W - 1, through: 0, by: -1) {
            let src = shards[colperm[V0 + x]]
            for row in 0..<x {
                let u = wrk[row * W + x]
                guard u != 0 else { continue }
                axpy(dst: &shards[colperm[V0 + row]], src: src, scalar: u, count: blockSize)
            }
        }

        return true
    }

    // MARK: - Inner operations

    // dst[i] ^= GF.mul(scalar, src[i])
    @inline(__always)
    private func axpy(dst: inout [UInt8], src: [UInt8], scalar: UInt8, count: Int) {
        if scalar == 0 { return }
        if scalar == 1 {
            for i in 0..<count { dst[i] ^= src[i] }
        } else {
            for i in 0..<count { dst[i] ^= GF.mul(scalar, src[i]) }
        }
    }

    @inline(__always)
    private func sShardScal(_ shard: inout [UInt8], scalar: UInt8, count: Int) {
        if scalar < 2 { return }
        for i in 0..<count { shard[i] = GF.mul(scalar, shard[i]) }
    }

    @inline(__always)
    private func wrkScal(_ wrk: inout [UInt8], start: Int, scalar: UInt8, count: Int) {
        if scalar < 2 { return }
        let end = min(start + count, wrk.count)
        for i in start..<end { wrk[i] = GF.mul(scalar, wrk[i]) }
    }

    @inline(__always)
    private func wrkAxpy(_ wrk: inout [UInt8], dstRow: Int, srcRow: Int, scalar: UInt8, count: Int) {
        if scalar == 0 { return }
        if scalar == 1 {
            for i in 0..<count { wrk[dstRow + i] ^= wrk[srcRow + i] }
        } else {
            for i in 0..<count { wrk[dstRow + i] ^= GF.mul(scalar, wrk[srcRow + i]) }
        }
    }
}

// MARK: - GF(2^8) arithmetic, polynomial 285

private enum GF {
    @inline(__always)
    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    // Tables from nanors/deps/obl/gf2_8_tables.h
    static let log: [UInt8] = [
        255,  0,  1, 25,  2, 50, 26,198,  3,223, 51,238, 27,104,199, 75,
          4,100,224, 14, 52,141,239,129, 28,193,105,248,200,  8, 76,113,
          5,138,101, 47,225, 36, 15, 33, 53,147,142,218,240, 18,130, 69,
         29,181,194,125,106, 39,249,185,201,154,  9,120, 77,228,114,166,
          6,191,139, 98,102,221, 48,253,226,152, 37,179, 16,145, 34,136,
         54,208,148,206,143,150,219,189,241,210, 19, 92,131, 56, 70, 64,
         30, 66,182,163,195, 72,126,110,107, 58, 40, 84,250,133,186, 61,
        202, 94,155,159, 10, 21,121, 43, 78,212,229,172,115,243,167, 87,
          7,112,192,247,140,128, 99, 13,103, 74,222,237, 49,197,254, 24,
        227,165,153,119, 38,184,180,124, 17, 68,146,217, 35, 32,137, 46,
         55, 63,209, 91,149,188,207,205,144,135,151,178,220,252,190, 97,
        242, 86,211,171, 20, 42, 93,158,132, 60, 57, 83, 71,109, 65,162,
         31, 45, 67,216,183,123,164,118,196, 23, 73,236,127, 12,111,246,
        108,161, 59, 82, 41,157, 85,170,251, 96,134,177,187,204, 62, 90,
        203, 89, 95,176,156,169,160, 81, 11,245, 22,235,122,117, 44,215,
         79,174,213,233,230,231,173,232,116,214,244,234,168, 80, 88,175,
    ]

    // 512 entries: allows log[a]+log[b] up to 508 without modular reduction.
    static let exp: [UInt8] = [
          1,  2,  4,  8, 16, 32, 64,128, 29, 58,116,232,205,135, 19, 38,
         76,152, 45, 90,180,117,234,201,143,  3,  6, 12, 24, 48, 96,192,
        157, 39, 78,156, 37, 74,148, 53,106,212,181,119,238,193,159, 35,
         70,140,  5, 10, 20, 40, 80,160, 93,186,105,210,185,111,222,161,
         95,190, 97,194,153, 47, 94,188,101,202,137, 15, 30, 60,120,240,
        253,231,211,187,107,214,177,127,254,225,223,163, 91,182,113,226,
        217,175, 67,134, 17, 34, 68,136, 13, 26, 52,104,208,189,103,206,
        129, 31, 62,124,248,237,199,147, 59,118,236,197,151, 51,102,204,
        133, 23, 46, 92,184,109,218,169, 79,158, 33, 66,132, 21, 42, 84,
        168, 77,154, 41, 82,164, 85,170, 73,146, 57,114,228,213,183,115,
        230,209,191, 99,198,145, 63,126,252,229,215,179,123,246,241,255,
        227,219,171, 75,150, 49, 98,196,149, 55,110,220,165, 87,174, 65,
        130, 25, 50,100,200,141,  7, 14, 28, 56,112,224,221,167, 83,166,
         81,162, 89,178,121,242,249,239,195,155, 43, 86,172, 69,138,  9,
         18, 36, 72,144, 61,122,244,245,247,243,251,235,203,139, 11, 22,
         44, 88,176,125,250,233,207,131, 27, 54,108,216,173, 71,142,  1,
          2,  4,  8, 16, 32, 64,128, 29, 58,116,232,205,135, 19, 38, 76,
        152, 45, 90,180,117,234,201,143,  3,  6, 12, 24, 48, 96,192,157,
         39, 78,156, 37, 74,148, 53,106,212,181,119,238,193,159, 35, 70,
        140,  5, 10, 20, 40, 80,160, 93,186,105,210,185,111,222,161, 95,
        190, 97,194,153, 47, 94,188,101,202,137, 15, 30, 60,120,240,253,
        231,211,187,107,214,177,127,254,225,223,163, 91,182,113,226,217,
        175, 67,134, 17, 34, 68,136, 13, 26, 52,104,208,189,103,206,129,
         31, 62,124,248,237,199,147, 59,118,236,197,151, 51,102,204,133,
         23, 46, 92,184,109,218,169, 79,158, 33, 66,132, 21, 42, 84,168,
         77,154, 41, 82,164, 85,170, 73,146, 57,114,228,213,183,115,230,
        209,191, 99,198,145, 63,126,252,229,215,179,123,246,241,255,227,
        219,171, 75,150, 49, 98,196,149, 55,110,220,165, 87,174, 65,130,
         25, 50,100,200,141,  7, 14, 28, 56,112,224,221,167, 83,166, 81,
        162, 89,178,121,242,249,239,195,155, 43, 86,172, 69,138,  9, 18,
         36, 72,144, 61,122,244,245,247,243,251,235,203,139, 11, 22, 44,
         88,176,125,250,233,207,131, 27, 54,108,216,173, 71,142,
    ]

    static let inv: [UInt8] = [
          0,  1,142,244, 71,167,122,186,173,157,221,152, 61,170, 93,150,
        216,114,192, 88,224, 62, 76,102,144,222, 85,128,160,131, 75, 42,
        108,237, 57, 81, 96, 86, 44,138,112,208, 31, 74, 38,139, 51,110,
         72,137,111, 46,164,195, 64, 94, 80, 34,207,169,171, 12, 21,225,
         54, 95,248,213,146, 78,166,  4, 48,136, 43, 30, 22,103, 69,147,
         56, 35,104,140,129, 26, 37, 97, 19,193,203, 99,151, 14, 55, 65,
         36, 87,202, 91,185,196, 23, 77, 82,141,239,179, 32,236, 47, 50,
         40,209, 17,217,233,251,218,121,219,119,  6,187,132,205,254,252,
         27, 84,161, 29,124,204,228,176, 73, 49, 39, 45, 83,105,  2,245,
         24,223, 68, 79,155,188, 15, 92, 11,220,189,148,172,  9,199,162,
         28,130,159,198, 52,194, 70,  5,206, 59, 13, 60,156,  8,190,183,
        135,229,238,107,235,242,191,175,197,100,  7,123,149,154,174,182,
         18, 89,165, 53,101,184,163,158,210,247, 98, 90,133,125,168, 58,
         41,113,200,246,249, 67,215,214, 16,115,118,120,153, 10, 25,145,
         20, 63,230,240,134,177,226,241,250,116,243,180,109, 33,178,106,
        227,231,181,234,  3,143,211,201, 66,212,232,117,127,255,126,253,
    ]
}

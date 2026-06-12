//
//  NanorsDecoder.swift
//  ChloroFrame
//
//  Swift wrapper around the self-contained C Reed-Solomon in nanors_impl.c.
//  Used when useSwiftFEC = false in Settings.
//
//  cf_rs is an opaque C struct, so all pointers to it are OpaquePointer in Swift.
//  The C API uses a flat contiguous buffer (totalShards * blockSize bytes), so
//  this wrapper flattens [[UInt8]] before the call and copies recovered shards back.

import Foundation

final class NanorsDecoder: ReedSolomonCoder {
    private let rs: OpaquePointer  // cf_rs *
    private let ds: Int
    private let ps: Int

    init?(dataShards: Int, parityShards: Int) {
        guard let ptr = cf_rs_new(Int32(dataShards), Int32(parityShards)) else { return nil }
        rs = ptr
        ds = dataShards
        ps = parityShards
    }

    deinit { cf_rs_free(rs) }

    func decode(shards: inout [[UInt8]], marks: [Bool], blockSize: Int) -> Bool {
        let total = ds + ps
        guard shards.count >= total, marks.count >= total else { return false }

        // Fast path: no data shards missing.
        guard marks[0..<ds].contains(true) else { return true }

        // Flatten into one contiguous buffer; missing shards contribute zeroed slots.
        var flat = [UInt8](repeating: 0, count: total * blockSize)
        for i in 0..<total where !marks[i] {
            let src = shards[i]
            let len = min(src.count, blockSize)
            flat.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    memcpy(dst.baseAddress!.advanced(by: i * blockSize),
                           s.baseAddress!, len)
                }
            }
        }

        // Build C-compatible marks (0 = present, 1 = missing).
        var cmarks = marks.prefix(total).map { $0 ? UInt8(1) : UInt8(0) }

        let ret: Int32 = flat.withUnsafeMutableBytes { flatPtr in
            cmarks.withUnsafeBytes { marksPtr in
                cf_rs_decode(
                    rs,
                    flatPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    marksPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    Int32(total),
                    Int32(blockSize)
                )
            }
        }

        guard ret == 0 else { return false }

        // Copy recovered data shards back.
        for i in 0..<ds where marks[i] {
            shards[i] = Array(flat[(i * blockSize)..<((i + 1) * blockSize)])
        }
        return true
    }
}

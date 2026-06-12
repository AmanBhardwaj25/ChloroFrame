//
//  ReedSolomonCoder.swift
//  ChloroFrame
//

// Protocol for GF(2^8) Reed-Solomon decode.
// shards[0..<ds] are data shards; shards[ds..<ds+ps] are parity shards.
// marks[i] = true means shard i is missing; must have len = ds + ps.
// Missing data shards must be allocated to blockSize bytes before calling decode —
// they will be overwritten with the recovered data on success.
protocol ReedSolomonCoder: AnyObject {
    func decode(shards: inout [[UInt8]], marks: [Bool], blockSize: Int) -> Bool
}

func makeReedSolomon(dataShards: Int, parityShards: Int, useSwift: Bool) -> ReedSolomonCoder? {
    if useSwift {
        return SwiftReedSolomon(dataShards: dataShards, parityShards: parityShards)
    } else {
        return NanorsDecoder(dataShards: dataShards, parityShards: parityShards)
    }
}

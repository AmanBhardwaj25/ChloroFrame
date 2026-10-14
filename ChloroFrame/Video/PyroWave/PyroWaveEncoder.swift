//
//  PyroWaveEncoder.swift
//  ChloroFrame
//
//  Thin wrapper over the vendored PyroWave Metal encoder. ChloroFrame never encodes
//  while streaming. This exists so the round-trip tests (D3) and the readiness
//  benchmark (D6) can make real bitstreams without a host. It lives in the app
//  module because the test target cannot see the bridging-header C symbols.
//

import Foundation

nonisolated final class PyroWaveEncoder: @unchecked Sendable {

    let width: Int
    let height: Int
    let chroma444: Bool

    private let device: PyroWaveDevice
    private let handle: pyrowave_encoder

    init(device: PyroWaveDevice, width: Int, height: Int, chroma444: Bool) throws {
        var info = pyrowave_encoder_create_info(
            device: device.handle,
            width: Int32(width),
            height: Int32(height),
            chroma: chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420)
        var created: pyrowave_encoder?
        let result = pyrowave_encoder_create(&info, &created)
        guard result == PYROWAVE_SUCCESS, let created else {
            throw PyroWaveError.failed("pyrowave_encoder_create", code: result.rawValue)
        }
        self.device = device
        self.handle = created
        self.width = width
        self.height = height
        self.chroma444 = chroma444
    }

    deinit { pyrowave_encoder_destroy(handle) }

    /// Encodes one 8-bit planar frame and returns its packets. Packet 0 starts with the
    /// sequence header; concatenating the packets gives a valid record frame.
    /// Planes are tightly packed (stride equals plane width).
    func encode(y: [UInt8], cb: [UInt8], cr: [UInt8],
                maximumBitstreamSize: Int, packetBoundary: Int = 1376) throws -> [Data] {
        let chromaWidth = chroma444 ? width : width / 2
        let chromaHeight = chroma444 ? height : height / 2
        guard y.count == width * height,
              cb.count == chromaWidth * chromaHeight,
              cr.count == cb.count else {
            throw PyroWaveError.invalidFormat("plane sizes do not match \(width)x\(height)")
        }

        let encodeResult: pyrowave_result = y.withUnsafeBytes { yp in
            cb.withUnsafeBytes { cbp in
                cr.withUnsafeBytes { crp in
                    var input = pyrowave_cpu_buffer()
                    input.data = (UnsafeMutableRawPointer(mutating: yp.baseAddress),
                                  UnsafeMutableRawPointer(mutating: cbp.baseAddress),
                                  UnsafeMutableRawPointer(mutating: crp.baseAddress))
                    input.row_stride_in_bytes = (width, chromaWidth, chromaWidth)
                    input.plane_size_in_bytes = (y.count, cb.count, cr.count)
                    input.width = Int32(width)
                    input.height = Int32(height)
                    input.format = chroma444 ? PYROWAVE_CPU_BUFFER_FORMAT_YUV444P
                                             : PYROWAVE_CPU_BUFFER_FORMAT_YUV420P
                    var rate = pyrowave_rate_control(maximum_bitstream_size: maximumBitstreamSize)
                    return pyrowave_encoder_encode_cpu(handle, &input, &rate)
                }
            }
        }
        guard encodeResult == PYROWAVE_SUCCESS else {
            throw PyroWaveError.failed("pyrowave_encoder_encode_cpu", code: encodeResult.rawValue)
        }

        var packetCount = 0
        var result = pyrowave_encoder_compute_num_packets(handle, packetBoundary, &packetCount)
        guard result == PYROWAVE_SUCCESS else {
            throw PyroWaveError.failed("pyrowave_encoder_compute_num_packets", code: result.rawValue)
        }

        // The rate control bounds the bitstream; the slack covers the sequence header
        // and per-packet rounding.
        var bitstream = [UInt8](repeating: 0, count: maximumBitstreamSize + 64 * 1024)
        var packets = [pyrowave_packet](repeating: pyrowave_packet(offset: 0, size: 0), count: packetCount)
        var written = 0
        result = bitstream.withUnsafeMutableBytes { out in
            pyrowave_encoder_packetize(handle, &packets, packetBoundary, &written,
                                       out.baseAddress, out.count)
        }
        guard result == PYROWAVE_SUCCESS else {
            throw PyroWaveError.failed("pyrowave_encoder_packetize", code: result.rawValue)
        }

        return packets.prefix(written).map { Data(bitstream[$0.offset ..< $0.offset + $0.size]) }
    }
}

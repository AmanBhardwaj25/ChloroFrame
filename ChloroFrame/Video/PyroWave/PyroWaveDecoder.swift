//
//  PyroWaveDecoder.swift
//  ChloroFrame
//
//  Per-stream PyroWave decoder. `submit` is called from the receive thread with a
//  reassembled, already trimmed record frame. Work happens on a private serial
//  queue (the C decoder object is not thread safe). A single-slot mailbox keeps
//  only the newest waiting frame: PyroWave frames are intra-only, so dropping a
//  stale one costs nothing and bounds latency when the GPU or queue falls behind.
//
//  Delivery happens from the command buffer's completed handler, which guarantees
//  the GPU writes are finished before the renderer touches the textures, even
//  though the renderer uses a different command queue.
//

import Foundation
import CoreMedia
import Metal
import QuartzCore

nonisolated final class PyroWaveDecoder: @unchecked Sendable {

    /// Cumulative counters, for the HUD (D6) and tests.
    struct Counters: Equatable {
        var submitted = 0
        var decoded = 0
        var parseRejects = 0       // record parser refused the frame (or the trim step did)
        var pushRejects = 0        // C parser refused a record
        var incomplete = 0         // decode_is_ready reported false
        var poolExhausted = 0
        var mailboxReplaced = 0
        var gpuFailures = 0
        /// Sum and peak of GPU execution time (`gpuEndTime - gpuStartTime`) over `decoded`
        /// frames, in milliseconds. `decodeAvgMs` is the per-frame average.
        var gpuMsTotal = 0.0
        var gpuMsMax = 0.0

        var decodeAvgMs: Double { decoded > 0 ? gpuMsTotal / Double(decoded) : 0 }
    }

    var onFrameDecoded: ((PlanarVideoFrame, CMTime) -> Void)?
    /// GPU execution time of each decode in milliseconds (`gpuEndTime - gpuStartTime`).
    /// Measurement hook; nil in normal streaming.
    var onGPUTime: ((Double) -> Void)?
    var stats: StreamStatsCollector?
    /// Decode frames that are missing blocks (missing blocks decode as zero, which
    /// blurs that area). Off by default: an incomplete frame is dropped. Partial
    /// delivery from the transport arrives in D10; the test suite uses this now.
    var allowPartialFrames = false

    let format: PyroWaveStreamFormat

    private struct Job {
        let data: Data
        let pts: CMTime
        let submitTime: Double
    }

    private let device: PyroWaveDevice
    private let decoder: pyrowave_decoder
    private let commandQueue: MTLCommandQueue
    private let pool: PlanarFramePool
    private let queue = DispatchQueue(label: "chloroframe.pyrowave-decode", qos: .userInteractive)

    private let lock = NSLock()
    private var pending: Job?
    private var drainScheduled = false
    private var counters = Counters()
    private var loggedRejects = 0
    private var reportedFirstFrame = false

    var counterSnapshot: Counters { lock.withLock { counters } }

    /// Textures come from this pool; tests read them back.
    var framePool: PlanarFramePool { pool }

    /// Creating the shared PyroWave device compiles shaders on first use, so build the
    /// decoder off the main thread (or call `PyroWaveDevice.warmUp` earlier).
    init(device mtlDevice: MTLDevice, format: PyroWaveStreamFormat,
         storageMode: MTLStorageMode = .private,
         color: PlanarColorParams? = nil) throws {
        guard format.width > 0, format.height > 0,
              format.width <= 16384, format.height <= 16384 else {
            throw PyroWaveError.invalidFormat("size \(format.width)x\(format.height)")
        }
        guard format.chroma444 || (format.width % 2 == 0 && format.height % 2 == 0) else {
            throw PyroWaveError.invalidFormat("4:2:0 needs even dimensions, got \(format.width)x\(format.height)")
        }
        guard format.bitDepth == 8 || format.bitDepth == 10 else {
            throw PyroWaveError.invalidFormat("bit depth \(format.bitDepth)")
        }
        guard let queue = mtlDevice.makeCommandQueue() else {
            throw PyroWaveError.failed("makeCommandQueue", code: 0)
        }

        let shared = try PyroWaveDevice.shared(for: mtlDevice)
        var info = pyrowave_decoder_create_info(
            device: shared.handle,
            width: Int32(format.width),
            height: Int32(format.height),
            chroma: format.chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420)
        var created: pyrowave_decoder?
        let result = pyrowave_decoder_create(&info, &created)
        guard result == PYROWAVE_SUCCESS, let created else {
            throw PyroWaveError.failed("pyrowave_decoder_create", code: result.rawValue)
        }

        self.format = format
        self.device = shared
        self.decoder = created
        self.commandQueue = queue
        self.commandQueue.label = "PyroWave decode"
        self.pool = PlanarFramePool(device: mtlDevice, width: format.width, height: format.height,
                                    chroma444: format.chroma444, bitDepth: format.bitDepth,
                                    storageMode: storageMode, color: color)
    }

    deinit {
        // Only reachable once the drain closure and every completed handler (which
        // capture self) have finished, so no GPU work still references the decoder.
        pyrowave_decoder_destroy(decoder)
    }

    /// Called from the receive thread. Never blocks on the GPU.
    func submit(frame: Data, pts: CMTime) {
        let job = Job(data: frame, pts: pts, submitTime: CACurrentMediaTime())
        var schedule = false
        var replaced = false
        lock.withLock {
            counters.submitted += 1
            if pending != nil {
                counters.mailboxReplaced += 1
                replaced = true
            }
            pending = job
            if !drainScheduled {
                drainScheduled = true
                schedule = true
            }
        }
        if replaced { stats?.recordFrameDropped() }
        if schedule { queue.async { [self] in drain() } }
    }

    /// A frame the transport could not trim to its real length. Counted with the parse rejects
    /// (the frame never reached the record parser), and as a dropped frame.
    func recordTrimReject() {
        lock.withLock { counters.parseRejects += 1 }
        stats?.recordFrameDropped()
    }

    // MARK: - Decode queue

    private func drain() {
        while true {
            let job: Job? = lock.withLock {
                let next = pending
                pending = nil
                if next == nil { drainScheduled = false }
                return next
            }
            guard let job else { return }
            process(job)
        }
    }

    private func process(_ job: Job) {
        // 1. Validate and split into records (padding stripped).
        let parsed = job.data.withUnsafeBytes {
            PyroWaveRecordParser.parse($0, expected: format)
        }
        let frame: PyroWaveRecordParser.Frame
        switch parsed {
        case .success(let f):
            frame = f
        case .failure(let failure):
            reject(.parse, "frame rejected: \(failure)")
            return
        }

        // 2. Clear before every frame so the 3-bit sequence counter never discards a
        //    frame after several consecutive drops (protocol doc, "Decoding").
        pyrowave_decoder_clear(decoder)

        // 3. Push the records.
        let pushed: Bool = job.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            for range in PyroWaveRecordParser.coalesced(frame.records) {
                let result = pyrowave_decoder_push_packet(decoder, base + range.lowerBound, range.count)
                if result != PYROWAVE_SUCCESS { return false }
            }
            return true
        }
        guard pushed else {
            reject(.push, "decoder refused a record")
            return
        }

        // 4. Complete?
        let ready = allowPartialFrames
            ? pyrowave_decoder_decode_is_ready_with_sideband(decoder, true, 0, 0.0, nil, 0)
            : pyrowave_decoder_decode_is_ready(decoder, false)
        guard ready else {
            reject(.incomplete, nil)
            return
        }

        // 5. Output textures.
        guard let planar = pool.acquire() else {
            reject(.pool, nil)
            return
        }

        // 6. Encode and commit. The completion handler delivers the frame.
        guard let cb = commandQueue.makeCommandBuffer() else {
            reject(.gpu, "makeCommandBuffer failed")
            return
        }
        cb.label = "PyroWave decode"
        var buffers = pyrowave_gpu_buffers(planes: (
            Unmanaged.passUnretained(planar.y).toOpaque(),
            Unmanaged.passUnretained(planar.cb).toOpaque(),
            Unmanaged.passUnretained(planar.cr).toOpaque()))
        let encoded = pyrowave_decoder_decode_gpu_buffer(decoder,
                                                         Unmanaged.passUnretained(cb).toOpaque(),
                                                         &buffers)
        guard encoded == PYROWAVE_SUCCESS else {
            reject(.gpu, "decode_gpu_buffer failed (\(encoded.rawValue))")
            return
        }

        let pts = job.pts
        let submitTime = job.submitTime
        cb.addCompletedHandler { [self] buffer in
            guard buffer.status == .completed else {
                reject(.gpu, "command buffer status \(buffer.status.rawValue): \(String(describing: buffer.error))")
                return
            }
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            onGPUTime?(gpuMs)
            let first: Bool = lock.withLock {
                counters.decoded += 1
                counters.gpuMsTotal += gpuMs
                counters.gpuMsMax = max(counters.gpuMsMax, gpuMs)
                let isFirst = !reportedFirstFrame
                reportedFirstFrame = true
                return isFirst
            }
            if first {
                // The HUD's "received" rows describe the first successfully decoded frame.
                stats?.setReceivedCodec(.pyrowave)
                stats?.setReceivedHdr(planar.color.isPQ)
            }
            stats?.recordFrameDecoded(latencyMs: (CACurrentMediaTime() - submitTime) * 1000)
            onFrameDecoded?(planar, pts)
        }
        cb.commit()
    }

    private enum RejectKind { case parse, push, incomplete, pool, gpu }

    private func reject(_ kind: RejectKind, _ message: String?) {
        var shouldLog = false
        lock.withLock {
            switch kind {
            case .parse: counters.parseRejects += 1
            case .push: counters.pushRejects += 1
            case .incomplete: counters.incomplete += 1
            case .pool: counters.poolExhausted += 1
            case .gpu: counters.gpuFailures += 1
            }
            if message != nil, loggedRejects < 5 {
                loggedRejects += 1
                shouldLog = true
            }
        }
        if shouldLog, let message { DebugFileLog.write("[PyroWaveDecoder] \(message)") }
        stats?.recordFrameDropped()
    }
}

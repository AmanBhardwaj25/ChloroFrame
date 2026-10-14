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

/// Sum, count and peak of one timed stage, in milliseconds.
nonisolated struct StageStat: Equatable {
    var sum = 0.0
    var count = 0
    var max = 0.0

    var avg: Double { count > 0 ? sum / Double(count) : 0 }

    mutating func add(_ ms: Double) {
        sum += ms
        count += 1
        if ms > max { max = ms }
    }
}

/// Where a PyroWave frame's wall time goes between assembly and the renderer (D7).
///
/// Receive thread: `rxTrimCopy` (assembled buffer to `Data`), `rxPacket` (slowest single
/// `addPacket` since the previous frame, which includes FEC, block staging and the frame emit).
/// Decode queue: `queueWait` (submit until the queue thread starts the job), `parse`, `push`
/// (clear, C push, ready check), `encode` (pool acquire, command buffer, GPU encode, commit).
/// GPU side: `commitToGPU` (commit until `gpuStartTime`), `gpu`, `completionLag` (`gpuEndTime`
/// until the completed handler runs). `total` is submit to completed handler.
nonisolated struct PyroWaveStageTimes: Equatable {
    var gap = StageStat()            // interval between consecutive submits
    var rxTrimCopy = StageStat()
    var rxPacket = StageStat()
    var queueWait = StageStat()
    var parse = StageStat()
    var push = StageStat()
    var encode = StageStat()
    var commitToGPU = StageStat()
    var gpu = StageStat()
    var completionLag = StageStat()
    var total = StageStat()

    // Why a frame was replaced in the single-slot mailbox.
    var replacedBurst = 0            // the replacing frame came less than `burstGapMs` after the previous one
    var replacedWhileProcessing = 0  // decode queue was busy inside process() (decode time)
    var replacedWhileWaiting = 0     // job was queued but the queue thread had not started it (wake latency)
    var replacedGap = StageStat()    // submit interval of the replacing frame
    var replacedAge = StageStat()    // how long the replaced frame had been waiting

    static let burstGapMs = 4.0
}

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
        /// Frames decoded with zero-filled holes (D10) and the block records they were missing,
        /// summed (`blocksSkipped`) and worst single frame (`blocksSkippedMax`).
        var partialDecoded = 0
        var blocksSkipped = 0
        var blocksSkippedMax = 0
        /// Sum and peak of GPU execution time (`gpuEndTime - gpuStartTime`) over `decoded`
        /// frames, in milliseconds. `decodeAvgMs` is the per-frame average.
        var gpuMsTotal = 0.0
        var gpuMsMax = 0.0
        /// Cumulative per-stage CPU and scheduling time (D7). Plain arithmetic on clock reads,
        /// so it is cheap enough to stay on in Release; only DEBUG builds ever print it.
        var stages = PyroWaveStageTimes()

        var decodeAvgMs: Double { decoded > 0 ? gpuMsTotal / Double(decoded) : 0 }
        var blocksSkippedPerPartial: Double {
            partialDecoded > 0 ? Double(blocksSkipped) / Double(partialDecoded) : 0
        }
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
        /// Set when the transport delivered the frame with zero-filled holes (D10).
        let lossMap: PyroWaveLossMap?
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
    private var reportedPQ: Bool?
    // Stage timing (D7). Guarded by `lock`.
    private var window = PyroWaveStageTimes()
    private var lastSubmitTime: Double?
    private var processStart: Double?

    var counterSnapshot: Counters { lock.withLock { counters } }

    /// Stage timings since the previous call (the 1 Hz DEBUG stats line); resets the window.
    func takeStageWindow() -> PyroWaveStageTimes {
        lock.withLock {
            let w = window
            window = PyroWaveStageTimes()
            return w
        }
    }

    /// Applies `body` to the cumulative stage times and to the current window. Caller holds `lock`.
    private func updateStages(_ body: (inout PyroWaveStageTimes) -> Void) {
        body(&counters.stages)
        body(&window)
    }

    /// Receive-thread cost of one frame, reported by the transport just before `submit`.
    func recordReceive(trimCopyMs: Double, slowestPacketMs: Double) {
        lock.withLock {
            updateStages {
                $0.rxTrimCopy.add(trimCopyMs)
                $0.rxPacket.add(slowestPacketMs)
            }
        }
    }

    /// Changes the color setup stamped on frames decoded from now on (the host's HDR mode
    /// message can turn PQ on or off after the stream started). Thread safe.
    func setColor(_ color: PlanarColorParams) { pool.color = color }

    /// The color setup new frames get.
    var currentColor: PlanarColorParams { pool.color }

    /// Textures come from this pool; tests read them back.
    var framePool: PlanarFramePool { pool }

    /// Creating the shared PyroWave device compiles shaders on first use, so build the
    /// decoder off the main thread (or call `PyroWaveDevice.warmUp` earlier).
    init(device mtlDevice: MTLDevice, format: PyroWaveStreamFormat,
         storageMode: MTLStorageMode = .private,
         color: PlanarColorParams? = nil) throws {
        if let problem = format.validationFailure {
            throw PyroWaveError.invalidFormat(problem)
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
    func submit(frame: Data, pts: CMTime, lossMap: PyroWaveLossMap? = nil) {
        let now = CACurrentMediaTime()
        let job = Job(data: frame, pts: pts, submitTime: now, lossMap: lossMap)
        var schedule = false
        var replaced = false
        lock.withLock {
            counters.submitted += 1
            let gapMs = lastSubmitTime.map { (now - $0) * 1000 }
            lastSubmitTime = now
            if let gapMs { updateStages { $0.gap.add(gapMs) } }
            if let old = pending {
                counters.mailboxReplaced += 1
                replaced = true
                let busy = processStart != nil
                let ageMs = (now - old.submitTime) * 1000
                updateStages {
                    if busy { $0.replacedWhileProcessing += 1 } else { $0.replacedWhileWaiting += 1 }
                    if let gapMs {
                        if gapMs < PyroWaveStageTimes.burstGapMs { $0.replacedBurst += 1 }
                        $0.replacedGap.add(gapMs)
                    }
                    $0.replacedAge.add(ageMs)
                }
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
        let t0 = CACurrentMediaTime()
        lock.withLock {
            processStart = t0
            updateStages { $0.queueWait.add((t0 - job.submitTime) * 1000) }
        }
        defer { lock.withLock { processStart = nil } }

        // 1. Validate and split into records (padding stripped).
        let parsed = job.data.withUnsafeBytes {
            PyroWaveRecordParser.parse($0, expected: format, lossMap: job.lossMap)
        }
        let t1 = CACurrentMediaTime()
        lock.withLock { updateStages { $0.parse.add((t1 - t0) * 1000) } }
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
        // A frame the transport delivered with holes is always decoded partially: the queue has
        // already checked the critical prefix, and PyroWave's own pristine-band check cannot
        // tell a lost block from an all-zero block that was never sent.
        let ready = (allowPartialFrames || job.lossMap != nil)
            ? pyrowave_decoder_decode_is_ready_with_sideband(decoder, true, 0, 0.0, nil, 0)
            : pyrowave_decoder_decode_is_ready(decoder, false)
        guard ready else {
            reject(.incomplete, nil)
            return
        }

        let t2 = CACurrentMediaTime()
        lock.withLock { updateStages { $0.push.add((t2 - t1) * 1000) } }

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
        // Blocks the parser could not use: announced by the sequence header, not recovered.
        let skippedBlocks: Int? = job.lossMap == nil ? nil : max(0, frame.totalBlocks - frame.blockRecordCount)
        let commitTime = CACurrentMediaTime()   // within microseconds of commit()
        cb.addCompletedHandler { [self] buffer in
            guard buffer.status == .completed else {
                reject(.gpu, "command buffer status \(buffer.status.rawValue): \(String(describing: buffer.error))")
                return
            }
            let handlerTime = CACurrentMediaTime()
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            lock.withLock {
                updateStages {
                    if buffer.gpuStartTime > commitTime {
                        $0.commitToGPU.add((buffer.gpuStartTime - commitTime) * 1000)
                    }
                    $0.gpu.add(gpuMs)
                    $0.completionLag.add(max(0, (handlerTime - buffer.gpuEndTime) * 1000))
                    $0.total.add((handlerTime - submitTime) * 1000)
                }
            }
            onGPUTime?(gpuMs)
            let first: Bool = lock.withLock {
                counters.decoded += 1
                if let skippedBlocks {
                    counters.partialDecoded += 1
                    counters.blocksSkipped += skippedBlocks
                    counters.blocksSkippedMax = max(counters.blocksSkippedMax, skippedBlocks)
                }
                counters.gpuMsTotal += gpuMs
                counters.gpuMsMax = max(counters.gpuMsMax, gpuMs)
                let isFirst = !reportedFirstFrame
                reportedFirstFrame = true
                return isFirst
            }
            if first {
                // The HUD's "received" rows describe the first successfully decoded frame.
                stats?.setReceivedCodec(.pyrowave)
            }
            // Also on a later PQ on/off flip from the host's HDR mode message (D9).
            let isPQ = planar.color.isPQ
            let pqChanged: Bool = lock.withLock {
                defer { reportedPQ = isPQ }
                return reportedPQ != isPQ
            }
            if pqChanged { stats?.setReceivedHdr(isPQ) }
            stats?.recordFrameDecoded(latencyMs: (CACurrentMediaTime() - submitTime) * 1000)
            onFrameDecoded?(planar, pts)
        }
        cb.commit()
        let t3 = CACurrentMediaTime()
        lock.withLock { updateStages { $0.encode.add((t3 - t2) * 1000) } }
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

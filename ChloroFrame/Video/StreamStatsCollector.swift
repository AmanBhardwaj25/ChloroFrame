//
//  StreamStatsCollector.swift
//  ChloroFrame
//
//  Thread-safe accumulator for stream health metrics. Record calls are lock-protected
//  and fire-and-forget from any thread; a 1-Hz timer on the main run loop snapshots
//  the accumulated state into the @Observable `current` property for SwiftUI.

import Foundation
import QuartzCore

// MARK: - Stats snapshot (read by UI, written only on main thread)

struct StreamStats {
    // What the client requested
    var reqWidth: Int = 0
    var reqHeight: Int = 0
    var reqFps: Int = 0
    var reqBitrateKbps: Int = 0
    var reqCodec: VideoCodec = .h264
    var reqHdr: Bool = false

    // Local reconstruction (super-resolution upscaling)
    var reconRequested: Bool = false   // user enabled it and the stream qualifies (sub-native, SDR)
    var reconActive: Bool = false      // scaler session actually created
    var reconOutW: Int = 0             // upscaled output width
    var reconOutH: Int = 0             // upscaled output height
    var reconReason: String = ""       // why it fell back (when requested but not active)
    var fgRequested: Bool = false      // frame generation requested
    var fgActive: Bool = false         // frame generation running
    var fgReason: String = ""          // why frame gen fell back

    // What actually arrived
    var measFps: Double = 0
    var measBitrateMbps: Double = 0
    var recvCodec: VideoCodec? = nil
    var recvHdr: Bool? = nil

    // Cumulative totals
    var packetsReceived: Int = 0
    var packetsRecovered: Int = 0
    var framesAssembled: Int = 0
    var framesLost: Int = 0
    var framesDecoded: Int = 0
    var framesDropped: Int = 0

    // Derived quality metrics
    var lossPercent: Double = 0      // frames lost / (assembled + lost)
    var fecRecoveryPct: Double = 0   // recovered packets / received packets
    var jitterMs: Double = 0         // RFC 3550 interarrival jitter, ms
    var decodeAvgMs: Double = 0
    var decodeMaxMs: Double = 0

    // Render-side presentation metrics (all windowed per 1-Hz snapshot)
    var drawIntervalMs: Double = 0        // avg wall-clock ms between draw() calls
    var drawIntervalP99Ms: Double = 0     // p99 draw interval — spikes here are microstutters
    var drawIntervalMaxMs: Double = 0     // worst draw interval in the window
    var frameAgeMs: Double = 0            // avg ms from enqueue to present (non-repeated frames only)
    var repeatedFramesPerSec: Double = 0  // draw ticks that reused the previous frame
    var overwrittenPerSec: Double = 0     // frames dropped at enqueue because queue was full
    var lateDroppedPerSec: Double = 0     // frames dropped at render because a newer frame was also due
    var renderQueueDepth: Double = 0      // avg queue occupancy over the snapshot window
    var renderQueueHighWatermark: Int = 0 // peak queue depth over the snapshot window

    // Audio-side metrics (sampled from AudioEngine.stats on the snapshot tick)
    var audioState: String = "—"      // stopped / priming / running
    var audioBufferedMs: Double = 0   // current ring-buffer occupancy in ms
    var audioUnderruns: Int = 0       // cumulative render-callback starvations (zero-fill)
    var audioOverruns: Int = 0        // cumulative ring overruns (oldest audio skipped)
    var audioDecoded: Int = 0         // cumulative Opus packets decoded
    var audioDriftDrops: Int = 0      // packets dropped by the drift servo (buffer too full)
    var audioDriftInserts: Int = 0    // packets duplicated by the drift servo (buffer too empty)
    var audioLoss: Int = 0            // forward sequence gaps (apparent packet loss)
    var audioReorder: Int = 0         // backwards-seq packets we discarded (reorder/dup)
    var audioLatencyClampMs: Double = 0 // cumulative ms skipped by the max-latency clamp (bursts)
    var audioTargetMs: Double = 0     // current adaptive jitter-buffer target latency
}

// MARK: - Collector

@Observable
final class StreamStatsCollector {

    // Snapshot published to the UI (main thread only)
    private(set) var current = StreamStats()

    // Requested config — set once before streaming, read on main thread
    var requestedWidth: Int = 0
    var requestedHeight: Int = 0
    var requestedFps: Int = 0
    var requestedBitrateKbps: Int = 0
    var requestedCodec: VideoCodec = .h264
    var requestedHdr: Bool = false

    // Local reconstruction state — set once at stream setup, read on the snapshot tick.
    private(set) var reconRequested = false
    private(set) var reconActive = false
    private(set) var reconOutW = 0
    private(set) var reconOutH = 0
    private(set) var reconReason = ""
    private(set) var fgRequested = false
    private(set) var fgActive = false
    private(set) var fgReason = ""

    /// Record the local upscaling state for the stats HUD. `requested` is true when the user
    /// enabled it and the stream qualified; `active` is true only if the scaler session was
    /// created (false means it fell back to the direct path, with `reason` explaining why).
    func setReconstruction(requested: Bool, active: Bool, outW: Int, outH: Int, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.reconRequested = requested
            self?.reconActive    = active
            self?.reconOutW      = outW
            self?.reconOutH      = outH
            self?.reconReason    = reason
        }
    }

    /// Record the frame-generation state for the stats HUD.
    func setFrameGen(requested: Bool, active: Bool, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.fgRequested = requested
            self?.fgActive    = active
            self?.fgReason    = reason
        }
    }

    // Received — set once when the first frame is successfully decoded
    private(set) var receivedCodec: VideoCodec? = nil
    private(set) var receivedHdr: Bool? = nil

    func setReceivedCodec(_ codec: VideoCodec) {
        DispatchQueue.main.async { [weak self] in self?.receivedCodec = codec }
    }

    func setReceivedHdr(_ hdr: Bool) {
        DispatchQueue.main.async { [weak self] in self?.receivedHdr = hdr }
    }

    // Pulls a fresh AudioEngineStats snapshot on each 1-Hz tick. Set by StreamTransport
    // once the AudioEngine exists; nil before that and after teardown. Invoked on the
    // main thread inside takeSnapshot — AudioEngine.stats does a short audioQueue.sync,
    // which never blocks on main, so this is deadlock-free.
    var audioStatsProvider: (() -> AudioEngineStats?)?

    // Pulls the audio receiver's loss/reorder counters on each tick. Set by StreamTransport.
    var audioReceiverStatsProvider: (() -> (loss: Int, reorder: Int)?)?

    // ── Lock-protected accumulator ────────────────────────────────────────

    private let lock = NSLock()

    private struct Acc {
        var packetsReceived: Int = 0
        var packetsRecovered: Int = 0
        var bytesReceived: Int = 0
        var framesAssembled: Int = 0
        var framesLost: Int = 0
        var framesDecoded: Int = 0
        var framesDropped: Int = 0

        // RFC 3550 §6.4.1 running jitter in 90 kHz ticks
        var jitterEst: Double = 0
        var prevRtpTs: UInt32 = 0
        var prevReceiveTime: Double = 0
        var hasPrevFrame: Bool = false

        // Decode latency rolling stats (not reset per-snapshot, max decays via replacement)
        var decodeTotalMs: Double = 0
        var decodeMaxMs: Double = 0
        var decodeCount: Int = 0

        // Window counters — reset each snapshot tick
        var snapFrames: Int = 0
        var snapBytes: Int = 0

        // Render-side accumulators — all reset each snapshot tick
        var snapDrawCount: Int = 0
        var snapDrawIntervalTotal: Double = 0
        // Per-window draw intervals for percentile computation (~120 entries/sec max;
        // capacity is retained across windows so appends are allocation-free at steady state).
        var snapDrawIntervals: [Double] = []
        var snapFrameAgeTotal: Double = 0
        var snapFrameAgeCount: Int = 0    // non-repeated draws only
        var snapRepeats: Int = 0
        var snapOverwritten: Int = 0
        var snapLateDropped: Int = 0
        var snapQueueDepthTotal: Double = 0
        var snapQueueDepthCount: Int = 0
        var snapQueueHighWatermark: Int = 0
    }

    private var acc = Acc()
    private var timer: Timer?
    private var lastSnapshotTime: Double = 0

    // MARK: - Lifecycle

    func start() {
        lastSnapshotTime = CACurrentMediaTime()
        SessionLog.shared.begin(header:
            "session start  req=\(requestedWidth)x\(requestedHeight)@\(requestedFps) "
            + "\(requestedBitrateKbps / 1000)Mbps codec=\(requestedCodec) hdr=\(requestedHdr)\n"
            + "columns: VIDEO fps · bitrate · loss% · jitter · decode(avg/max) · "
            + "draw(avg/p99/max) · frameAge · queue(avg/peak) · overwrites/s · lateDrops/s  ||  "
            + "AUDIO state · buffered · underruns · overruns · drift(drop/ins) · decoded")
        // Add to main run loop so the callback always fires on the main thread,
        // regardless of which thread start() is called from.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.takeSnapshot()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        SessionLog.shared.end()
    }

    // MARK: - Record (any thread)

    func recordPacket(bytes: Int) {
        lock.withLock {
            acc.packetsReceived += 1
            acc.bytesReceived += bytes
            acc.snapBytes += bytes
        }
    }

    func recordPacketsRecovered(_ n: Int) {
        lock.withLock { acc.packetsRecovered += n }
    }

    /// Call once per fully assembled frame, passing its RTP timestamp (90 kHz).
    func recordFrameAssembled(rtpTimestamp: UInt32) {
        let now = CACurrentMediaTime()
        lock.withLock {
            acc.framesAssembled += 1
            acc.snapFrames += 1

            // RFC 3550 §6.4.1:  D(i,j) = |( Rj − Ri ) − ( Sj − Si )|
            // Compute in 90 kHz units; convert to ms at snapshot time.
            if acc.hasPrevFrame {
                let rtpDelta  = Double(Int32(bitPattern: rtpTimestamp &- acc.prevRtpTs))
                let timeDelta = (now - acc.prevReceiveTime) * 90_000.0
                let d = abs(timeDelta - rtpDelta)
                acc.jitterEst += (d - acc.jitterEst) / 16.0
            }
            acc.prevRtpTs = rtpTimestamp
            acc.prevReceiveTime = now
            acc.hasPrevFrame = true
        }
    }

    func recordFrameLost() {
        lock.withLock { acc.framesLost += 1 }
    }

    /// Call with the elapsed wall-clock time for the VTDecompressionSession call.
    func recordFrameDecoded(latencyMs: Double) {
        lock.withLock {
            acc.framesDecoded += 1
            acc.decodeTotalMs += latencyMs
            acc.decodeCount += 1
            if latencyMs > acc.decodeMaxMs { acc.decodeMaxMs = latencyMs }
        }
    }

    func recordFrameDropped() {
        lock.withLock { acc.framesDropped += 1 }
    }

    /// One render tick's worth of stats in a single lock acquisition.
    /// - Parameters:
    ///   - queueDepth: queue occupancy after this tick's pops (average + occupancy)
    ///   - lateDrops: stale due frames dropped in favor of a newer due frame
    ///   - drawIntervalMs: ms since the previous presenting/starved tick; nil when the
    ///     tick presented nothing and wasn't starved (no draw recorded at all)
    ///   - frameAgeMs: enqueue-to-present age of the presented frame (ignored when repeated)
    ///   - repeated: true for a starved tick (no new frame; previous content stays on glass)
    func recordRenderTick(queueDepth: Int, lateDrops: Int,
                          drawIntervalMs: Double?, frameAgeMs: Double, repeated: Bool) {
        lock.withLock {
            acc.snapQueueDepthTotal += Double(queueDepth)
            acc.snapQueueDepthCount += 1
            acc.snapLateDropped += lateDrops
            if let intervalMs = drawIntervalMs {
                acc.snapDrawCount += 1
                acc.snapDrawIntervalTotal += intervalMs
                if intervalMs > 0 { acc.snapDrawIntervals.append(intervalMs) }
                if repeated {
                    acc.snapRepeats += 1
                } else {
                    acc.snapFrameAgeTotal += frameAgeMs
                    acc.snapFrameAgeCount += 1
                }
            }
        }
    }

    /// Called from enqueueFrame after appending, where queue depth is at its peak for
    /// this frame (render hasn't popped yet). Single lock for watermark + overwrites.
    func recordEnqueue(peakDepth: Int, overwritten: Int) {
        lock.withLock {
            if peakDepth > acc.snapQueueHighWatermark { acc.snapQueueHighWatermark = peakDepth }
            acc.snapOverwritten += overwritten
        }
    }

    // MARK: - Snapshot (main thread, 1 Hz)

    private func takeSnapshot() {
        let now = CACurrentMediaTime()
        let elapsed = max(now - lastSnapshotTime, 0.001)  // guard against zero or negative elapsed
        lastSnapshotTime = now

        let snap = lock.withLock { () -> Acc in
            let s = acc
            // Reset all per-window counters.
            acc.snapFrames = 0
            acc.snapBytes = 0
            acc.snapDrawCount = 0
            acc.snapDrawIntervalTotal = 0
            acc.snapDrawIntervals.removeAll(keepingCapacity: true)
            acc.snapFrameAgeTotal = 0
            acc.snapFrameAgeCount = 0
            acc.snapRepeats = 0
            acc.snapOverwritten = 0
            acc.snapLateDropped = 0
            acc.snapQueueDepthTotal = 0
            acc.snapQueueDepthCount = 0
            acc.snapQueueHighWatermark = 0
            return s
        }

        let fps          = Double(snap.snapFrames) / elapsed
        let bitrateMbps  = Double(snap.snapBytes) * 8.0 / 1_000_000.0 / elapsed
        let totalFrames  = snap.framesAssembled + snap.framesLost
        let lossPct      = totalFrames > 0 ? Double(snap.framesLost) / Double(totalFrames) * 100 : 0
        let fecPct       = snap.packetsReceived > 0 ? Double(snap.packetsRecovered) / Double(snap.packetsReceived) * 100 : 0
        let decodeAvg    = snap.decodeCount > 0 ? snap.decodeTotalMs / Double(snap.decodeCount) : 0

        let draws        = snap.snapDrawCount
        let drawInterval = draws > 0 ? snap.snapDrawIntervalTotal / Double(draws) : 0
        let frameAge     = snap.snapFrameAgeCount > 0 ? snap.snapFrameAgeTotal / Double(snap.snapFrameAgeCount) : 0
        let repeatsPerSec     = Double(snap.snapRepeats) / elapsed
        let overwrittenPerSec = Double(snap.snapOverwritten) / elapsed
        let lateDroppedPerSec = Double(snap.snapLateDropped) / elapsed
        let queueDepthAvg = snap.snapQueueDepthCount > 0
            ? snap.snapQueueDepthTotal / Double(snap.snapQueueDepthCount) : 0

        var drawIntervalP99 = 0.0
        var drawIntervalMax = 0.0
        if !snap.snapDrawIntervals.isEmpty {
            let sorted = snap.snapDrawIntervals.sorted()
            drawIntervalP99 = sorted[min(Int(Double(sorted.count) * 0.99), sorted.count - 1)]
            drawIntervalMax = sorted[sorted.count - 1]
        }

        let audio = audioStatsProvider?()
        let audioRx = audioReceiverStatsProvider?()

        // One line per second while streaming when verbose logging is enabled
        // (defaults write ... verboseStreamLogs -bool YES) — this is the before/after
        // artifact for pacing work. With verbose off, no string is even built.
        if draws > 0 {
            StreamLog.log("[ChloroFrame][video-stats] fps=\(String(format: "%.1f", fps)) draw=\(String(format: "%.2f", drawInterval))ms p99=\(String(format: "%.2f", drawIntervalP99))ms max=\(String(format: "%.2f", drawIntervalMax))ms repeats=\(String(format: "%.1f", repeatsPerSec))/s overwrites=\(String(format: "%.1f", overwrittenPerSec))/s lateDrops=\(String(format: "%.1f", lateDroppedPerSec))/s qAvg=\(String(format: "%.2f", queueDepthAvg)) qPeak=\(snap.snapQueueHighWatermark) age=\(String(format: "%.1f", frameAge))ms")
        }

        // Always-on session log line (1 Hz, async file I/O off the hot path). This is the
        // artifact we review after a run.
        let vLine = String(format:
            "VIDEO fps=%.1f br=%.1fMbps loss=%.1f%% jit=%.1fms dec=%.1f/%.1fms "
            + "draw=%.2f/%.2f/%.2fms age=%.1fms q=%.1f/%ld over=%.1f/s late=%.1f/s",
            fps, bitrateMbps, lossPct, snap.jitterEst / 90.0, decodeAvg, snap.decodeMaxMs,
            drawInterval, drawIntervalP99, drawIntervalMax, frameAge,
            queueDepthAvg, snap.snapQueueHighWatermark, overwrittenPerSec, lateDroppedPerSec)
        let aLine = "AUDIO \(audio?.state.label ?? "—") " + String(format:
            "buf=%.0fms tgt=%.0fms under=%ld over=%ld drift=%ld/%ld clamp=%.0fms dec=%ld loss=%ld reorder=%ld",
            audio?.bufferedMs ?? 0, audio?.targetMs ?? 0, audio?.underrunCount ?? 0, audio?.overrunCount ?? 0,
            audio?.driftDrops ?? 0, audio?.driftInserts ?? 0, audio?.latencyClampMs ?? 0,
            audio?.decodeCount ?? 0, audioRx?.loss ?? 0, audioRx?.reorder ?? 0)
        SessionLog.shared.line(vLine + "  ||  " + aLine)

        current = StreamStats(
            reqWidth: requestedWidth,
            reqHeight: requestedHeight,
            reqFps: requestedFps,
            reqBitrateKbps: requestedBitrateKbps,
            reqCodec: requestedCodec,
            reqHdr: requestedHdr,
            reconRequested: reconRequested,
            reconActive: reconActive,
            reconOutW: reconOutW,
            reconOutH: reconOutH,
            reconReason: reconReason,
            fgRequested: fgRequested,
            fgActive: fgActive,
            fgReason: fgReason,
            measFps: fps,
            measBitrateMbps: bitrateMbps,
            recvCodec: receivedCodec,
            recvHdr: receivedHdr,
            packetsReceived: snap.packetsReceived,
            packetsRecovered: snap.packetsRecovered,
            framesAssembled: snap.framesAssembled,
            framesLost: snap.framesLost,
            framesDecoded: snap.framesDecoded,
            framesDropped: snap.framesDropped,
            lossPercent: lossPct,
            fecRecoveryPct: fecPct,
            jitterMs: snap.jitterEst / 90.0,
            decodeAvgMs: decodeAvg,
            decodeMaxMs: snap.decodeMaxMs,
            drawIntervalMs: drawInterval,
            drawIntervalP99Ms: drawIntervalP99,
            drawIntervalMaxMs: drawIntervalMax,
            frameAgeMs: frameAge,
            repeatedFramesPerSec: repeatsPerSec,
            overwrittenPerSec: overwrittenPerSec,
            lateDroppedPerSec: lateDroppedPerSec,
            renderQueueDepth: queueDepthAvg,
            renderQueueHighWatermark: snap.snapQueueHighWatermark,
            audioState:        audio?.state.label ?? "—",
            audioBufferedMs:   audio?.bufferedMs ?? 0,
            audioUnderruns:    audio?.underrunCount ?? 0,
            audioOverruns:     audio?.overrunCount ?? 0,
            audioDecoded:      audio?.decodeCount ?? 0,
            audioDriftDrops:   audio?.driftDrops ?? 0,
            audioDriftInserts: audio?.driftInserts ?? 0,
            audioLoss:         audioRx?.loss ?? 0,
            audioReorder:      audioRx?.reorder ?? 0,
            audioLatencyClampMs: audio?.latencyClampMs ?? 0,
            audioTargetMs:     audio?.targetMs ?? 0
        )
    }
}

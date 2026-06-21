//
//  RTPVideoReceiver.swift
//  ChloroFrame
//

import Foundation
import Network
import CoreMedia
import VideoToolbox
import os

// Receives RTP video datagrams from Apollo.
//
// The same UDP socket is used for both SS_PING (outbound) and RTP receive (inbound).
// Apollo sends video TO the client port declared in RTSP SETUP (X-GS-ClientPort).
// We must bind our socket to that exact local port so the OS routes those datagrams to us.
//
// Opt-H: this is a raw POSIX socket, not NWConnection, for two reasons:
//   1. SO_RCVBUF = 4 MB. The default kernel buffer can overflow during a ~30 ms
//      scheduler stall at high bitrate — silent packet loss → IDR request → freeze.
//      NWConnection offers no setsockopt access.
//   2. A dedicated blocking recv() thread replaces one dispatch hop per datagram
//      (~2,500/s at 120 fps) and re-arms implicitly, so FEC/assembly work can never
//      delay the next receive being posted.
//
// Raw datagrams are fed into RtpVideoQueue which handles:
//   - NV_VIDEO_PACKET header parsing and fecInfo decoding
//   - Packet reordering by RTP sequence number
//   - Reed-Solomon FEC recovery for missing data shards
//   - Multi-FEC block reassembly for large frames
//
// The queue assembles whole frames internally and emits each one via onFrameAssembled
// as a borrowed Annex-B view; this receiver converts it to AVCC and hands it to
// VideoDecoder (which copies into its own Data before the decode job is queued).

final class RTPVideoReceiver {

    private var socketFD: Int32 = -1
    private var receiveThread: Thread?
    // Set by stop(); checked by the receive loop after every recv() wakeup.
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private var pingTask: Task<Void, Never>?
    private let decoder: VideoDecoder
    private let videoCodec: VideoCodec
    private let streamFps: Int

    private var vpsData: Data?   // HEVC only
    private var spsData: Data?
    private var ppsData: Data?

    // Fired (from the RtpVideoQueue callback thread) when a frame is unrecoverable.
    // StreamTransport wires this to send an IDR request to the server.
    var onFrameLost: ((UInt32) -> Void)?

    // True after a lost frame; gates processFrame to drop P-frames until the next IDR arrives.
    private var waitingForIdr = false

    // Set by StreamTransport after init; forwarded to the queue.
    var stats: StreamStatsCollector? {
        didSet { queue.stats = stats }
    }

    private let queue: RtpVideoQueue

    init(decoder: VideoDecoder, packetSize: Int = 1392, videoCodec: VideoCodec = .h264, streamFps: Int = 120) {
        self.decoder = decoder
        self.videoCodec = videoCodec
        self.streamFps = streamFps > 0 ? streamFps : 120
        let useSwift = UserDefaults.standard.bool(forKey: "useSwiftFEC")
        queue = RtpVideoQueue(packetSize: packetSize, useSwiftFEC: useSwift)
    }

    /// Binds the UDP socket and sends the first SS_PING before returning.
    /// Callers must await this so Start A/B is sent only after the socket is ready.
    func start(host: String, serverPort: UInt16, localPort: UInt16, pingPayload: String) async throws {
        queue.onFrameAssembled = { [weak self] _, annexB, rtpTimestamp in
            guard let self else { return }
            self.advanceRtpTimeline(rtpTimestamp)
            self.processFrame(annexB)
        }

        queue.onFrameLost = { [weak self] frameNumber in
            guard let self else { return }
            self.waitingForIdr = true
            self.onFrameLost?(frameNumber)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ReceiverError.socketCreateFailed(errno) }
        var fdOwned = true
        defer { if fdOwned { close(fd) } }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Opt-H: 4 MB receive buffer. At 120 fps × ~20 pkts × ~1.4 KB, a 30 ms
        // preemption spike is ~100 KB — the headroom absorbs IDR bursts on top.
        var rcvBuf: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var actualBuf: Int32 = 0
        var actualLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualBuf, &actualLen)

        // Opt-A equivalent of NWParameters.serviceClass = .interactiveVideo:
        // NET_SERVICE_TYPE_VI marks DSCP AF41 → WMM AC_VI on Wi-Fi.
        var serviceType: Int32 = NET_SERVICE_TYPE_VI
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))

        // Opt-D equivalent of params.requiredInterface: pin to the Wi-Fi interface
        // so replies can't route over awdl0. NetworkMonitor has been running since
        // app launch; the interface is already known. macOS-only: tvOS has no AWDL
        // competition concern (often Ethernet) and does not do interface discovery
        // (port plan 6.4), so the IP_BOUND_IF lock and NetworkMonitor dependency are
        // dropped there.
        #if os(macOS)
        if let iface = NetworkMonitor.shared.wifiInterface {
            var ifIndex = UInt32(iface.index)
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            print("[RTPVideoReceiver] WiFi interface locked to '\(iface.name)' (index \(iface.index))")
        } else {
            print("[RTPVideoReceiver] WARNING: no cached WiFi interface; AWDL lock skipped")
        }
        #endif

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = localPort.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ReceiverError.bindFailed(errno) }

        // connect() the UDP socket to the server so the kernel filters foreign
        // datagrams and send()/recv() can be used without per-call addresses.
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(serverPort), &hints, &resolved) == 0, let addrInfo = resolved else {
            throw ReceiverError.resolveFailed(host)
        }
        defer { freeaddrinfo(addrInfo) }
        guard Darwin.connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen) == 0 else {
            throw ReceiverError.connectFailed(errno)
        }

        print("[RTPVideoReceiver] socket ready localPort=\(localPort) SO_RCVBUF=\(actualBuf)")

        socketFD = fd
        fdOwned = false  // ownership passes to the receive thread (it closes on exit)

        let thread = Thread { [weak self] in self?.receiveLoop(fd: fd) }
        thread.name = "chloroframe.video-rx"
        thread.qualityOfService = .userInteractive
        receiveThread = thread
        thread.start()

        // First SS_PING goes out synchronously before start() returns, so the caller's
        // ordering guarantee (socket bound + pinged before Start A/B) actually holds.
        sendPing(fd: fd, payload: pingPayload, seq: 0)
        startPing(fd: fd, payload: pingPayload)
    }

    func stop() {
        pingTask?.cancel()
        stopping.withLock { $0 = true }
        if socketFD >= 0 {
            // Wake the blocking recv(); the receive thread checks `stopping`,
            // closes the fd itself, and exits.
            shutdown(socketFD, SHUT_RDWR)
            socketFD = -1
        }
    }

    // MARK: - Receive loop (dedicated thread)

    private func receiveLoop(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var transientErrorCount = 0
        while !stopping.withLock({ $0 }) {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                stats?.recordPacket(bytes: n)
                // The queue copies what it keeps before returning, so the receive
                // buffer can be handed over as a borrowed view — no Data per datagram.
                buf.withUnsafeBytes { raw in
                    queue.addPacket(UnsafeRawBufferPointer(rebasing: raw[0..<n]))
                }
            } else if n == 0 {
                // Zero-length datagram (Apollo never sends these) or shutdown wakeup;
                // the loop condition decides which.
                continue
            } else {
                let err = errno
                if err == EINTR { continue }
                // Connected UDP surfaces ICMP port-unreachable as ECONNREFUSED while
                // the server's sender isn't up yet — transient, keep receiving.
                if err == ECONNREFUSED && transientErrorCount < 50 {
                    transientErrorCount += 1
                    continue
                }
                if !stopping.withLock({ $0 }) {
                    print("[RTPVideoReceiver] recv failed errno=\(err) — receive loop exiting")
                }
                break
            }
        }
        close(fd)
    }

    // MARK: - SS_PING outbound

    private func startPing(fd: Int32, payload: String) {
        pingTask = Task { [weak self] in
            var seq: UInt32 = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.sendPing(fd: fd, payload: payload, seq: seq)
                seq &+= 1
            }
        }
    }

    private func sendPing(fd: Int32, payload: String, seq: UInt32) {
        guard !stopping.withLock({ $0 }) else { return }
        let d = makePing(payload: payload, seq: seq)
        d.withUnsafeBytes { raw in
            _ = send(fd, raw.baseAddress, raw.count, 0)
        }
    }

    private func makePing(payload: String, seq: UInt32) -> Data {
        var d = Data(capacity: 20)
        let ascii = Array(payload.utf8.prefix(16))
        d.append(contentsOf: ascii)
        while d.count < 16 { d.append(0) }
        d.append(UInt8(seq >> 24 & 0xFF))
        d.append(UInt8(seq >> 16 & 0xFF))
        d.append(UInt8(seq >>  8 & 0xFF))
        d.append(UInt8(seq       & 0xFF))
        return d
    }

    // MARK: - Frame processing

    private var framesProcessed = 0
    // RTP timestamp (90 kHz capture clock) unwrapped to a monotonic 64-bit timeline.
    // This is the PTS source: it reflects when the server actually captured each
    // frame. frameIndex / streamFps was tried and is WRONG — when the game renders
    // below the negotiated fps, frameIndex still advances by 1 per sent frame, so
    // that timeline runs slower than wall time, every frame looks permanently late,
    // and the playout buffer can never build (observed: zero buffering and constant
    // repeat-stutter whenever game fps < stream fps).
    private var lastRtpTs: UInt32 = 0
    private var extendedRtpTs: Int64 = 0
    private var haveRtpTs = false

    private func advanceRtpTimeline(_ ts: UInt32) {
        guard haveRtpTs else {
            haveRtpTs = true
            lastRtpTs = ts
            extendedRtpTs = 0
            return
        }
        let delta = Int64(Int32(bitPattern: ts &- lastRtpTs))  // wrap-aware signed delta
        lastRtpTs = ts
        // Plausibility: 1–120 fps content gives 90 kHz deltas of 750…90000. A
        // non-positive or >1 s delta means the server timestamp isn't behaving like
        // a clock — substitute nominal frame spacing rather than corrupt the timeline.
        if delta > 0 && delta <= 90_000 {
            extendedRtpTs += delta
        } else {
            extendedRtpTs += Int64(90_000 / max(streamFps, 1))
        }
    }

    private func processFrame(_ annexB: UnsafeBufferPointer<UInt8>) {
        let (sample, hasKeyFrame) = buildAVCCSample(from: annexB)

        // After a lost frame, drop P-frames until the next IDR arrives.
        // H.264: IDR is signalled by an accompanying SPS (type 7).
        // HEVC:  IDR is signalled by an accompanying VPS (type 32).
        // Capture whether this frame is the post-loss IDR so the clock reset can be
        // embedded in the same decode job, not in a separately queued async block.
        let isResetFrame = waitingForIdr && hasKeyFrame
        if waitingForIdr {
            if !hasKeyFrame { return }
            waitingForIdr = false
        }

        framesProcessed += 1

        if !decoder.isReady {
            let fmt: CMFormatDescription?
            if videoCodec == .hevc {
                guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return }
                fmt = VideoFormatHelper.createHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
            } else {
                guard let sps = spsData, let pps = ppsData else { return }
                fmt = VideoFormatHelper.createH264FormatDescription(sps: sps, pps: pps)
            }
            guard let fmt else { return }
            do {
                try decoder.setup(for: fmt)
                stats?.setReceivedCodec(videoCodec)
                // setReceivedHdr is called by VideoDecoder on the first decoded frame using
                // actual frame metadata (PQ+BT.2020+matrix). Don't call it here with decoder.isHdr
                // ("we requested HDR") — that would make the HUD lie before the first frame arrives.
            } catch {
                // Rare error path — always log.
                print("[RTPVideoReceiver] decoder setup failed: \(error) — waiting for next IDR")
                waitingForIdr = true
                return
            }
        }

        guard decoder.isReady, !sample.isEmpty else { return }
        let pts = CMTime(value: extendedRtpTs, timescale: 90_000)
        decoder.decode(nalUnit: sample, presentationTime: pts, resetClockBeforeOutput: isResetFrame)
    }

    // MARK: - Helpers

    /// Single-pass Annex-B → AVCC converter. Scans the borrowed `annexBData` view for
    /// start codes and writes each non-parameter-set NAL as [4-byte BE length][NAL bytes]
    /// into the returned Data. Parameter-set NALs (VPS/SPS/PPS/AUD) update instance vars.
    /// Returns (avccSample, hasKeyFrame): hasKeyFrame is true when SPS(H.264) or VPS(HEVC) seen.
    private func buildAVCCSample(from annexBData: UnsafeBufferPointer<UInt8>) -> (Data, Bool) {
        var out = Data(capacity: annexBData.count)
        var hasKeyFrame = false

        func copyNAL(start: Int, end: Int) -> Data {
            Data(bytes: annexBData.baseAddress! + start, count: end - start)
        }

        func flushNAL(start: Int, end: Int) {
            var e = end
            while e > start && annexBData[e - 1] == 0 { e -= 1 }
            guard e > start else { return }
            let nalByte = annexBData[start]
            if videoCodec == .hevc {
                let t = (nalByte >> 1) & 0x3F
                switch t {
                case 32: vpsData = copyNAL(start: start, end: e); hasKeyFrame = true
                case 33: spsData = copyNAL(start: start, end: e)
                case 34: ppsData = copyNAL(start: start, end: e)
                default: break
                }
                // VPS(32), SPS(33), PPS(34), AUD(35) belong outside the HVCC sample.
                if t < 32 || t == 39 || t == 40 {
                    let v = UInt32(e - start)
                    out.append(UInt8(v >> 24 & 0xFF)); out.append(UInt8(v >> 16 & 0xFF))
                    out.append(UInt8(v >>  8 & 0xFF)); out.append(UInt8(v        & 0xFF))
                    out.append(UnsafeBufferPointer(rebasing: annexBData[start..<e]))
                }
            } else {
                let t = nalByte & 0x1F
                switch t {
                case 7: spsData = copyNAL(start: start, end: e); hasKeyFrame = true
                case 8: ppsData = copyNAL(start: start, end: e)
                default: break
                }
                // SPS(7), PPS(8), AUD(9) belong outside the AVCC sample.
                if t != 7 && t != 8 && t != 9 {
                    let v = UInt32(e - start)
                    out.append(UInt8(v >> 24 & 0xFF)); out.append(UInt8(v >> 16 & 0xFF))
                    out.append(UInt8(v >>  8 & 0xFF)); out.append(UInt8(v        & 0xFF))
                    out.append(UnsafeBufferPointer(rebasing: annexBData[start..<e]))
                }
            }
        }

        var nalStart = -1
        var i = 0
        while i < annexBData.count {
            if let scLen = annexBStartCodeLength(annexBData, i) {
                if nalStart >= 0 { flushNAL(start: nalStart, end: i) }
                nalStart = i + scLen
                i += scLen
            } else {
                i += 1
            }
        }
        if nalStart >= 0 { flushNAL(start: nalStart, end: annexBData.count) }

        return (out, hasKeyFrame)
    }

    enum ReceiverError: Error {
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case resolveFailed(String)
        case connectFailed(Int32)
    }

    private func annexBStartCodeLength(_ data: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        guard i + 3 <= data.count else { return nil }
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            return 3
        }
        if i + 4 <= data.count &&
            data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
            return 4
        }
        return nil
    }

}

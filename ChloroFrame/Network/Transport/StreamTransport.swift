//
//  StreamTransport.swift
//  ChloroFrame
//

import Foundation
import Network
import CoreMedia
import CoreVideo
import CryptoKit

// Manages all post-RTSP transport streams for an active session:
//   - ENet control    (controlServerPort): session keepalive + input
//   - Video UDP       (videoServerPort):   SS_PING + RTP receive → VideoDecoder
//   - Audio UDP       (audioServerPort):   SS_PING + RTP receive → Opus decode → AVAudioEngine
//
// Apollo won't send any media until it receives the first UDP ping on each port.
// The ENet control connection must also be up within ping_timeout (default 10 s).

final class StreamTransport {

    private let desc: StreamDescriptor
    private let enet = ENetClient()
    private let rikey: Data

    private var videoReceiver:       RTPVideoReceiver?
    // Audio decode is macOS-only until tvOS gets a libopus build or switches to the
    // AudioToolbox decoder (port plan 7.4). Guarded so the shared transport compiles
    // for tvOS without the macOS-arm64 libopus link dependency.
    #if os(macOS)
    private var audioReceiver:       RTPAudioReceiver?
    private var audioEngine:         AudioEngine?
    #endif
    private var inputHeartbeatTask:  Task<Void, Never>?

    var onENetDisconnect: (() -> Void)?
    var onVideoTexture:   ((CVPixelBuffer, CMTime) -> Void)?
    var onClockReset:     (() -> Void)?

    let stats = StreamStatsCollector()
    private var streamActivity: NSObjectProtocol?

    init(descriptor: StreamDescriptor, config: StreamConfig, rikey: Data) {
        self.desc = descriptor
        self.rikey = rikey

        stats.requestedWidth = config.width
        stats.requestedHeight = config.height
        stats.requestedFps = config.fps
        stats.requestedBitrateKbps = config.bitrate
        stats.requestedCodec = config.codec
    }

    // MARK: - Lifecycle

    /// Start all transport streams. Must be called immediately after RTSP PLAY.
    func start() async throws {
        streamActivity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiatedAllowingIdleSystemSleep],
            reason: "Active stream"
        )
        #if os(macOS)
        AWDLSuppressor.shared.suppress()
        #endif
        // Clean up all partially-created resources if anything below throws.
        var startSucceeded = false
        defer {
            if !startSucceeded {
                if let activity = streamActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    streamActivity = nil
                }
                // Stop any receivers/engine that may have been started before the throw.
                videoReceiver?.stop(); videoReceiver = nil
                #if os(macOS)
                audioReceiver?.stop(); audioReceiver = nil
                audioEngine?.stop();   audioEngine   = nil
                #endif
                stats.stop()
                enet.disconnect()
                #if os(macOS)
                AWDLSuppressor.shared.restore()
                #endif
            }
        }

        enet.rikey = SymmetricKey(data: rikey)
        enet.onDisconnect = { [weak self] in self?.onENetDisconnect?() }

        try await enet.connect(
            host:        desc.serverHost,
            port:        desc.controlServerPort,
            connectData: desc.controlConnectData
        )

        let serverHost      = desc.serverHost
        let videoPing       = desc.videoPingPayload
        let audioPing       = desc.audioPingPayload
        let videoPort       = desc.videoServerPort
        let audioPort       = desc.audioServerPort
        let videoLocalPort  = desc.videoLocalPort
        let audioLocalPort  = desc.audioLocalPort

        // RTSP PLAY already fired inside RTSPClient.negotiate() before we get here.
        // Apollo *could* start sending media immediately after PLAY, but in practice it waits
        // for Start A (0x0302) on the ENet control channel. We bind both UDP sockets and send
        // SS_PING on each before issuing Start A/B so that no burst packets land on unbound ports.
        let decoder = VideoDecoder()
        decoder.isHdr = desc.dynamicRangeMode != 0
        decoder.onFrameDecoded = { [weak self] pixelBuffer, pts in
            self?.onVideoTexture?(pixelBuffer, pts)
        }
        // Route the clock-reset signal out so the renderer can clear its anchor.
        // This fires from the decode thread just before the first post-loss IDR is forwarded,
        // so the anchor is guaranteed to clear before the IDR re-establishes it.
        decoder.onClockReset = { [weak self] in self?.onClockReset?() }
        decoder.stats = stats
        stats.requestedHdr = desc.dynamicRangeMode != 0

        let vr = RTPVideoReceiver(decoder: decoder,
                                  packetSize: desc.videoPacketSize,
                                  videoCodec: desc.videoCodec,
                                  streamFps: stats.requestedFps)
        vr.stats = stats
        vr.onFrameLost = { [weak self] frameNumber in
            // Gen7Enc IDR request: type 0x0302, payload [0,0], channel 1 (CTRL_CHANNEL_URGENT).
            // Proof: moonlight-common-c ControlStream.c:204,228 packetTypesGen7Enc + requestIdrFrameGen7Enc.
            self?.enet.sendControl(type: 0x0302, payload: [0x00, 0x00], channel: 0x01)
            // Clock reset is now embedded in the IDR frame's decode job via resetClockBeforeOutput.
            // RTPVideoReceiver.processFrame sets isResetFrame=true when waitingForIdr && hasKeyFrame,
            // so no separate scheduleClockReset() dispatch is needed here.
        }
        // Await socket .ready so both ports are bound before Start A/B fires.
        // The OS delivers the initial IDR burst immediately after Start A; if the
        // socket doesn't exist yet, those packets are dropped and video never starts.
        try await vr.start(host: serverHost, serverPort: videoPort, localPort: videoLocalPort, pingPayload: videoPing)
        videoReceiver = vr

        stats.start()

        #if os(macOS)
        let engine = AudioEngine()
        try engine.start()
        audioEngine = engine
        stats.audioStatsProvider = { [weak engine] in engine?.stats }

        let ar = RTPAudioReceiver()
        ar.onPacket = { [weak engine] packet in engine?.push(packet: packet) }
        stats.audioReceiverStatsProvider = { [weak ar] in ar.map { ($0.apparentLoss, $0.reorderDiscarded) } }
        try await ar.start(host: serverHost, serverPort: audioPort, localPort: audioLocalPort, pingPayload: audioPing)
        audioReceiver = ar
        #endif

        // Both sockets are now bound and SS_PING has been sent.
        // Start A/B triggers the server to begin streaming.
        // Start A (type 0x0302) tells Sunshine to begin streaming on the encrypted control path.
        // Start B (type 0x0307) confirms readiness.
        print("[ChloroFrame][transport] sending Start A (0x0302) + Start B (0x0307)")
        enet.sendControl(type: 0x0302, payload: [0x00, 0x00])
        enet.sendControl(type: 0x0307, payload: [0x00])

        // Sunshine has an application-level input inactivity timeout (distinct from the ENet
        // keepalive). If no input events arrive for ~60–90 s it sends a DISCONNECT. A null
        // relative mouse move (dx=0, dy=0) counts as an input event and resets the timer
        // without visibly moving anything on the remote.
        inputHeartbeatTask = Task { [weak self] in await self?.inputHeartbeatLoop() }

        startSucceeded = true
    }

    func stop(reason: String = "caller") {
        print("[ChloroFrame][transport] stop reason=\(reason)")
        if let activity = streamActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamActivity = nil
        }
        #if os(macOS)
        AWDLSuppressor.shared.restore()
        #endif
        stats.stop()
        stats.audioStatsProvider = nil
        stats.audioReceiverStatsProvider = nil
        videoReceiver?.stop();          videoReceiver      = nil
        #if os(macOS)
        audioReceiver?.stop();          audioReceiver      = nil
        audioEngine?.stop();            audioEngine        = nil
        #endif
        inputHeartbeatTask?.cancel();   inputHeartbeatTask = nil
        enet.disconnect()
    }

    /// Send a pre-built NV_INPUT_HEADER packet over ENet control (type 0x0206).
    /// Called by InputHandler; channel is input-type-specific (0x02 keyboard, 0x03 mouse).
    func sendInput(packet: [UInt8], channel: UInt8) {
        enet.sendControl(type: 0x0206, payload: packet, channel: channel)
    }

    // MARK: - Input heartbeat loop

    private func inputHeartbeatLoop() async {
        // NV_MOUSE_MOVE_REL: BE32(8) | LE32(0x07) | BE16(0) | BE16(0)
        // dx=0, dy=0 — no visible movement on the remote, but Sunshine registers it as input.
        let heartbeat: [UInt8] = [
            0x00, 0x00, 0x00, 0x08,   // BE32(8)
            0x07, 0x00, 0x00, 0x00,   // LE32(0x07) — relative mouse move
            0x00, 0x00,               // deltaX = 0
            0x00, 0x00,               // deltaY = 0
        ]
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
            guard !Task.isCancelled else { return }
            sendInput(packet: heartbeat, channel: 0x03)
        }
    }

}

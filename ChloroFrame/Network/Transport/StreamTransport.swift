//
//  StreamTransport.swift
//  ChloroFrame
//

import Foundation
import Network
import CoreMedia
import CoreVideo
import CryptoKit
import Metal
import QuartzCore

// Manages all post-RTSP transport streams for an active session:
//   - ENet control    (controlServerPort): session keepalive + input
//   - Video UDP       (videoServerPort):   SS_PING + RTP receive → VideoDecoder
//   - Audio UDP       (audioServerPort):   SS_PING + RTP receive → Opus decode → AVAudioEngine
//
// Apollo won't send any media until it receives the first UDP ping on each port.
// The ENet control connection must also be up within ping_timeout (default 10 s).

final class StreamTransport {

    private let desc: StreamDescriptor
    private let streamWidth: Int
    private let streamHeight: Int
    private var pyroWaveDecoder: PyroWaveDecoder?
    private let enet = ENetClient()
    private let rikey: Data

    private var videoReceiver:       RTPVideoReceiver?
    private var audioReceiver:       RTPAudioReceiver?
    private var audioEngine:         AudioEngine?
    private var inputHeartbeatTask:  Task<Void, Never>?

    var onENetDisconnect: (() -> Void)?
    var onVideoTexture:   ((CVPixelBuffer, CMTime) -> Void)?
    // PyroWave frames arrive as three planar textures instead of a CVPixelBuffer.
    var onPlanarFrame:    ((PlanarVideoFrame, CMTime) -> Void)?
    // The renderer's device. Required when the negotiated codec is PyroWave, so the decoder
    // writes textures the renderer can sample.
    var metalDevice:      MTLDevice?
    var onClockReset:     (() -> Void)?
    var onAudioRecoveryStatusChange: ((AudioRecoveryStatus) -> Void)?
    // Fires once, ~5s after Start A/B, if no video packet has arrived by then (Phase 5). A
    // connected-but-silent path (control channel up, UDP blocked somewhere) would otherwise
    // just sit there with no feedback until the control connection eventually times out.
    var onNoMediaReceived: (() -> Void)?

    let stats = StreamStatsCollector()
    private var streamActivity: NSObjectProtocol?
    private var noMediaWatchdog: DispatchWorkItem?
    private let watchdogQueue = DispatchQueue(label: "chloroframe.streamtransport.watchdog")

    init(descriptor: StreamDescriptor, config: StreamConfig, rikey: Data) {
        self.desc = descriptor
        self.rikey = rikey
        self.streamWidth = config.width
        self.streamHeight = config.height

        stats.requestedWidth = config.width
        stats.requestedHeight = config.height
        stats.requestedFps = config.fps
        stats.requestedBitrateKbps = config.bitrate
        stats.requestedCodec = config.codec
    }

    // MARK: - Lifecycle

    /// Restart the audio engine in place (fallback "Retry audio" action, CP4). Re-primes and
    /// re-binds to the current default output device; no-op if audio was never started.
    func retryAudio() {
        audioEngine?.restart()
    }

    /// Start all transport streams. Must be called immediately after RTSP PLAY.
    func start() async throws {
        // Streaming input arrives over the network, not from local HID, so the system sees an
        // idle Mac and would dim/sleep the display mid-session (common when the player uses a
        // controller paired to the host PC). .idleDisplaySleepDisabled holds a
        // PreventUserIdleDisplaySleep assertion for the lifetime of the activity, which also
        // implies idle system sleep stays disabled.
        streamActivity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated, .idleDisplaySleepDisabled],
            reason: "Active stream"
        )
        AWDLSuppressor.shared.suppress()
        // Clean up all partially-created resources if anything below throws.
        var startSucceeded = false
        defer {
            if !startSucceeded {
                if let activity = streamActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    streamActivity = nil
                }
                // Stop any receivers/engine that may have been started before the throw.
                pyroWaveDecoder?.onFrameDecoded = nil; pyroWaveDecoder = nil
                stats.pyroWaveStatsProvider = nil
                stats.pyroWaveStageProvider = nil
                videoReceiver?.stop(); videoReceiver = nil
                audioReceiver?.stop(); audioReceiver = nil
                audioEngine?.stop();   audioEngine   = nil
                stats.stop()
                enet.disconnect()
                AWDLSuppressor.shared.restore()
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

        // Pin media sockets to Wi-Fi only when Wi-Fi is actually the route to the host (keeps
        // AWDL suppression on a LAN-over-Wi-Fi stream, without forcing a Tailscale/VPN/
        // Ethernet route onto Wi-Fi, where it has no path to the destination). See
        // RouteResolver / design/tailscale-connection-fix-plan.md.
        let wifiInterface = NetworkMonitor.shared.wifiInterface
        let pinToWiFi = wifiInterface != nil && desc.route?.interfaceName == wifiInterface?.name
        let pinInterfaceIndex: UInt32? = pinToWiFi ? UInt32(wifiInterface!.index) : nil
        let pinNWInterface: NWInterface? = pinToWiFi ? wifiInterface : nil

        stats.pathInterface  = desc.route?.interfaceName ?? "unknown"
        stats.pathClass      = desc.networkClass == .local ? "local" : "remote"
        stats.pathPacketSize = desc.videoPacketSize
        #if DEBUG
        if let route = desc.route {
            Swift.print("[ChloroFrame][transport] route dest=\(route.destination) "
                      + "iface=\(route.interfaceName) mtu=\(route.interfaceMTU.map(String.init) ?? "?") "
                      + "pin=\(pinToWiFi ? "wifi" : "none")")
        } else {
            Swift.print("[ChloroFrame][transport] route resolution failed; pin=none")
        }
        #endif

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

        // PyroWave: build the decoder now, before Start A/B, so the first frames are not lost
        // to a lazy shader compile. The device's pipelines are normally already warm
        // (PyroWaveDevice.warmUp at negotiation); this call is a cache hit then.
        var pyroWave: PyroWaveDecoder?
        if desc.videoCodec == .pyrowave {
            pyroWave = try await makePyroWaveDecoder()
            pyroWaveDecoder = pyroWave
        }

        let vr = RTPVideoReceiver(decoder: decoder,
                                  packetSize: desc.videoPacketSize,
                                  videoCodec: desc.videoCodec,
                                  streamFps: stats.requestedFps,
                                  pyroWaveDecoder: pyroWave)
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
        try await vr.start(host: serverHost, serverPort: videoPort, localPort: videoLocalPort,
                          pingPayload: videoPing, pinInterfaceIndex: pinInterfaceIndex,
                          family: desc.route?.family ?? AF_INET)
        videoReceiver = vr

        stats.start()

        let engine = AudioEngine()
        engine.onRecoveryStatusChange = { [weak self] status in
            self?.onAudioRecoveryStatusChange?(status)
        }
        try engine.start()
        audioEngine = engine
        stats.audioStatsProvider = { [weak engine] in engine?.stats }

        let ar = RTPAudioReceiver()
        ar.onPacket = { [weak engine] packet in engine?.push(packet: packet) }
        stats.audioReceiverStatsProvider = { [weak ar] in ar.map { ($0.apparentLoss, $0.reorderDiscarded) } }
        try await ar.start(host: serverHost, serverPort: audioPort, localPort: audioLocalPort,
                          pingPayload: audioPing, requiredInterface: pinNWInterface,
                          family: desc.route?.family ?? AF_INET)
        audioReceiver = ar

        // Both sockets are now bound and SS_PING has been sent.
        // Start A/B triggers the server to begin streaming.
        // Start A (type 0x0302) tells Sunshine to begin streaming on the encrypted control path.
        // Start B (type 0x0307) confirms readiness.
        print("[ChloroFrame][transport] sending Start A (0x0302) + Start B (0x0307)")
        enet.sendControl(type: 0x0302, payload: [0x00, 0x00])
        enet.sendControl(type: 0x0307, payload: [0x00])

        // No-media watchdog (Phase 5): if the control channel is healthy but no video packet
        // shows up within 5s of Start A/B, the network path is silently dropping UDP somewhere
        // (a not-uncommon symptom on a VPN/Tailscale path even after HTTP/RTSP succeeded, since
        // those go over TCP). Surface that specifically instead of leaving the user looking at a
        // black screen with no explanation until the control connection eventually gives up.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.stats.packetsReceivedSoFar == 0 else { return }
            self.onNoMediaReceived?()
        }
        noMediaWatchdog = watchdog
        watchdogQueue.asyncAfter(deadline: .now() + 5, execute: watchdog)

        // Sunshine has an application-level input inactivity timeout (distinct from the ENet
        // keepalive). If no input events arrive for ~60–90 s it sends a DISCONNECT. A null
        // relative mouse move (dx=0, dy=0) counts as an input event and resets the timer
        // without visibly moving anything on the remote.
        inputHeartbeatTask = Task { [weak self] in await self?.inputHeartbeatLoop() }

        startSucceeded = true
    }

    /// Creates the PyroWave decoder for the negotiated stream: 4:2:0 or 4:4:4 per the negotiated
    /// chroma, 8-bit or 10-bit per `dynamicRangeMode`, with range and matrix taken from the
    /// `encoderCscMode` SDPBuilder announced (decision Q3). A 10-bit stream is assumed to be
    /// HDR10 (BT.2020 PQ) until the host's HDR mode message says otherwise (D9).
    private func makePyroWaveDecoder() async throws -> PyroWaveDecoder {
        guard let device = metalDevice else {
            throw PyroWaveError.failed("no Metal device was passed to the transport", code: 0)
        }
        let format = PyroWaveStreamFormat(width: streamWidth, height: streamHeight,
                                          chroma444: desc.chroma444, bitDepth: desc.dynamicRangeMode != 0 ? 10 : 8)
        // D7 resolution sanity: 4:2:0 planes need even dimensions. HostConnectionView already
        // rounds overrides to even; this refuses a stream that slipped past it, in every build.
        if let problem = format.validationFailure {
            DebugFileLog.write("[ChloroFrame][pyrowave] refusing stream format: \(problem)")
            throw PyroWaveError.invalidFormat(problem)
        }
        let tenBit = format.bitDepth == 10
        let cscMode = SDPBuilder.encoderCscMode(codec: .pyrowave, hdr: tenBit)
        let color = PlanarColorParams.forEncoderCscMode(cscMode, bitDepth: format.bitDepth, hdr: tenBit)
        // Off the main actor: the first creation per MTLDevice compiles the decode shaders.
        let decoder = try await Task.detached(priority: .userInitiated) {
            try PyroWaveDecoder(device: device, format: format, color: color)
        }.value
        decoder.stats = stats
        // Review R1: a 10-bit stream holds its first frames until the host's HDR mode message
        // says PQ or SDR (at most 250 ms), so an SDR host does not flash through the PQ path.
        let colorGate = PyroWaveColorGate(waitForHost: tenBit)
        decoder.onFrameDecoded = { [weak self] frame, pts in
            guard colorGate.allows(frame.color, now: CACurrentMediaTime()) else { return }
            self?.onPlanarFrame?(frame, pts)
        }
        // D9: the host says whether the 10-bit picture is PQ HDR or 10-bit SDR. An 8-bit stream
        // has no HDR, so the message is ignored there.
        if tenBit {
            enet.setHdrModeHandler { [weak decoder] enabled in
                guard let decoder else { return }
                let updated = PlanarColorParams.forEncoderCscMode(cscMode, bitDepth: 10, hdr: enabled)
                colorGate.hostReported(updated)
                #if DEBUG
                DebugFileLog.write("[ChloroFrame][pyrowave] host HDR mode message enabled=\(enabled) "
                                 + "-> matrix=\(updated.matrix) transfer=\(updated.transfer) "
                                 + "changed=\(updated != decoder.currentColor) heldFrames=\(colorGate.heldFrames)")
                #endif
                guard updated != decoder.currentColor else { return }
                decoder.setColor(updated)
            }
        }
        stats.pyroWaveProfileLabel = "\(format.chroma444 ? "4:4:4" : "4:2:0") \(format.bitDepth)-bit"
        stats.pyroWaveStatsProvider = { [weak decoder] in decoder?.counterSnapshot }
        stats.pyroWaveBitstreamMismatch = desc.pyroWaveBitstreamMismatch
        #if DEBUG
        stats.pyroWaveStageProvider = { [weak decoder] in decoder?.takeStageWindow() }
        #endif
        #if DEBUG
        DebugFileLog.write("[ChloroFrame][pyrowave] decoder ready \(format.width)x\(format.height) "
                         + "chroma444=\(format.chroma444) bitDepth=\(format.bitDepth) cscMode=\(cscMode) "
                         + "fullRange=\(color.fullRange) matrix=\(color.matrix) transfer=\(color.transfer) "
                         + "packetSize=\(desc.videoPacketSize)")
        #endif
        return decoder
    }

    func stop(reason: String = "caller") {
        print("[ChloroFrame][transport] stop reason=\(reason)")
        noMediaWatchdog?.cancel()
        noMediaWatchdog = nil
        if let activity = streamActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamActivity = nil
        }
        AWDLSuppressor.shared.restore()
        stats.stop()
        stats.audioStatsProvider = nil
        stats.audioReceiverStatsProvider = nil
        stats.pyroWaveStatsProvider = nil
        stats.pyroWaveStageProvider = nil
        pyroWaveDecoder?.onFrameDecoded = nil; pyroWaveDecoder = nil
        videoReceiver?.stop();          videoReceiver      = nil
        audioReceiver?.stop();          audioReceiver      = nil
        audioEngine?.stop();            audioEngine        = nil
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

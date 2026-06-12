//
//  RTSPClient.swift
//  ChloroFrame
//

import Foundation
import Network

// Convenience shorthands for RTSP logging into the shared session log.
private func rtspLog(_ text: String, step: String) {
    AppLogger.shared.log(text, "RTSP", step)
}
private func rtspLogBlock(_ header: String, body: String, step: String) {
    AppLogger.shared.logBlock(header, body: body, "RTSP", step)
}

// MARK: - Types

enum VideoCodec {
    case h264, hevc, av1
}

/// Everything the RTP receiver needs after a successful RTSP handshake.
struct StreamDescriptor {
    let videoCodec:          VideoCodec
    let dynamicRangeMode:    Int      // 0 = SDR, 1 = HDR10 (PQ + BT.2020 + P010)
    let serverHost:          String
    let videoServerPort:     UInt16   // server sends video FROM this port
    let videoLocalPort:      UInt16   // we bind a UDP socket on this port
    let audioServerPort:     UInt16
    let audioLocalPort:      UInt16
    // Session identifiers returned by SETUP (requires ML_FF_SESSION_ID_V1 in featureFlags)
    let audioPingPayload:    String   // X-SS-Ping-Payload from SETUP audio (16 hex chars)
    let videoPingPayload:    String   // X-SS-Ping-Payload from SETUP video (16 hex chars)
    let controlServerPort:   UInt16   // ENet/UDP port for control (base+10)
    let controlConnectData:  UInt32   // X-SS-Connect-Data from SETUP control (ENet connect)
    // Video packet bytes after the RTP header. This includes NV_VIDEO_PACKET plus
    // compressed video payload, matching Moonlight's StreamConfig.packetSize.
    // Used as the per-shard row size for RS FEC (blockSize = videoPacketSize + RTP header).
    let videoPacketSize:     Int
}

enum RTSPError: LocalizedError {
    case badURL
    case connectFailed(String)
    case badStatus(Int, String)
    case badResponse(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .badURL:                        return "Invalid RTSP session URL"
        case .connectFailed(let m):          return "RTSP connect failed: \(m)"
        case .badStatus(let c, let ctx):     return "RTSP \(c) during \(ctx)"
        case .badResponse(let m):            return "Malformed RTSP response: \(m)"
        case .closed:                        return "RTSP connection closed unexpectedly"
        }
    }
}

// MARK: - Stream configuration

/// Parameters sent to Sunshine in the DESCRIBE SDP body so it can configure the encoder.
struct StreamConfig {
    var width:   Int    = 1920
    var height:  Int    = 1080
    var fps:     Int    = 60
    var bitrate: Int    = 10000   // kbps, total including FEC headroom
    var codec:   VideoCodec = .h264
    var hdr:     Bool   = false   // HDR10 (PQ + BT.2020 + P010); requires HEVC
}

// MARK: - RTSPClient

/// Performs the RTSP handshake (OPTIONS → DESCRIBE → SETUP × 3 → ANNOUNCE → PLAY)
/// required by Apollo/Sunshine. Apollo closes the TCP socket after every response,
/// so request() opens a fresh connection for each method.
final class RTSPClient {

    // Moonlight's StreamConfig.packetSize: bytes after the RTP header. This includes
    // NV_VIDEO_PACKET plus compressed video payload and must match the SDP attribute.
    private static let videoPacketSize = 1392

    private var connection: NWConnection?
    private var buffer     = Data()
    private var cseq       = 0
    private var sessionId: String?
    private var serverHost = ""
    private var serverPort: UInt16 = 48010

    // MARK: - Public

    func negotiate(sessionURL: URL, config: StreamConfig = StreamConfig()) async throws -> StreamDescriptor {
        guard let host = sessionURL.host() else { throw RTSPError.badURL }
        serverHost = host
        serverPort = UInt16(sessionURL.port ?? 48010)
        // request() opens a fresh TCP connection before each message.
        // Apollo closes the socket after every response — persistent connections are not supported.

        print("[ChloroFrame][rtsp] negotiate start  host=\(host):\(serverPort)")
        // ── OPTIONS ──────────────────────────────────────────────────────────
        _ = try await request("OPTIONS", uri: "*", extra: [:])

        // ── DESCRIBE ─────────────────────────────────────────────────────────
        // No body from client — only Accept + If-Modified-Since.
        // The client capability SDP goes in ANNOUNCE (after all SETUPs), not here.
        let desc = try await request("DESCRIBE", uri: "/", extra: [
            "Accept":            "application/sdp",
            "If-Modified-Since": "Thu, 01 Jan 1970 00:00:00 GMT",
        ])
        guard desc.status == 200 else { throw RTSPError.badStatus(desc.status, "DESCRIBE") }

        // Sunshine always supports SS_ENC_CONTROL_V2 (12-byte nonce AES-GCM).
        // We hard-enable it; the value sent in ANNOUNCE tells both sides to use the same IV format.
        let encryptionEnabled: UInt32 = 1

        let ifModSince = "Thu, 01 Jan 1970 00:00:00 GMT"

        // ── SETUP audio ──────────────────────────────────────────────────────
        // X-GS-ClientPort declares the LOCAL port Apollo will send audio TO.
        // Must match the port we actually bind our audio socket to.
        let aSetup = try await request("SETUP", uri: "streamid=audio/0/0", extra: [
            "Transport":         "unicast;X-GS-ClientPort=48000-48001",
            "If-Modified-Since": ifModSince,
        ])
        guard aSetup.status == 200 else { throw RTSPError.badStatus(aSetup.status, "SETUP audio") }
        sessionId = sessionIDValue(from: aSetup.headers["session"] ?? "")
        let audioServerPort  = serverRTPPort(from: aSetup.headers["transport"] ?? "", fallback: 48000)
        let audioPingPayload = aSetup.headers["x-ss-ping-payload"] ?? ""

        // ── SETUP video ──────────────────────────────────────────────────────
        // Must match videoLocalPort = 47998 (also declared in ANNOUNCE m=video).
        let vSetup = try await request("SETUP", uri: "streamid=video/0/0", extra: [
            "Transport":         "unicast;X-GS-ClientPort=47998-47999",
            "If-Modified-Since": ifModSince,
        ])
        guard vSetup.status == 200 else { throw RTSPError.badStatus(vSetup.status, "SETUP video") }
        let videoServerPort  = serverRTPPort(from: vSetup.headers["transport"] ?? "", fallback: 47998)
        let videoPingPayload = vSetup.headers["x-ss-ping-payload"] ?? ""

        // ── SETUP control ────────────────────────────────────────────────────
        let cSetup = try await request("SETUP", uri: "streamid=control/13/0", extra: [
            "Transport":         "unicast;X-GS-ClientPort=47999-48000",
            "If-Modified-Since": ifModSince,
        ])
        let controlServerPort  = serverRTPPort(from: cSetup.headers["transport"] ?? "", fallback: 47999)
        let controlConnectData = UInt32(
            cSetup.headers["x-ss-connect-data"]?.trimmingCharacters(in: .whitespaces) ?? "0"
        ) ?? 0

        // ── ANNOUNCE ─────────────────────────────────────────────────────────
        // Client capability SDP (resolution, bitrate, codec, x-nv-*/x-ss-*/x-ml-* attrs).
        let announceSDP  = buildDescribeSDP(serverHost: host, videoLocalPort: 47998, config: config,
                                            encryptionEnabled: encryptionEnabled)
        print("[ChloroFrame][rtsp] ANNOUNCE encryptionEnabled=\(encryptionEnabled)")
        let announceData = Data(announceSDP.utf8)
        let announce = try await request("ANNOUNCE", uri: "streamid=control/13/0", extra: [
            "Content-type":   "application/sdp",
            "Content-length": "\(announceData.count)",
        ], body: announceData)
        guard announce.status == 200 else { throw RTSPError.badStatus(announce.status, "ANNOUNCE") }

        // ── PLAY ─────────────────────────────────────────────────────────────
        // AppVersion >= 7.1.431: single PLAY to "/" starts all streams simultaneously.
        let play = try await request("PLAY", uri: "/", extra: [:])
        guard play.status == 200 else { throw RTSPError.badStatus(play.status, "PLAY") }

        // X-GS-PacketSize may tell us the actual packet size Sunshine will use. If it is
        // absent, use the same value we advertised in ANNOUNCE so the FEC shard width
        // remains consistent with the encoder.
        let gsPacketSize = Int(play.headers["x-gs-packetsize"]?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        let negotiatedPacketSize = gsPacketSize > 0 ? gsPacketSize : Self.videoPacketSize
        rtspLog("video packet size advertised=\(Self.videoPacketSize) playHeader=\(gsPacketSize) using=\(negotiatedPacketSize)", step: "PLAY")
        print("[ChloroFrame][rtsp] PLAY OK → video:\(videoServerPort) audio:\(audioServerPort) control:\(controlServerPort) connectData=\(controlConnectData) packetSize=\(negotiatedPacketSize)")

        return StreamDescriptor(
            videoCodec:          config.codec,
            dynamicRangeMode:    config.hdr ? 1 : 0,
            serverHost:          host,
            videoServerPort:     videoServerPort,
            videoLocalPort:      47998,
            audioServerPort:     audioServerPort,
            audioLocalPort:      48000,
            audioPingPayload:    audioPingPayload,
            videoPingPayload:    videoPingPayload,
            controlServerPort:   controlServerPort,
            controlConnectData:  controlConnectData,
            videoPacketSize:     negotiatedPacketSize
        )
    }

    func disconnect() {
        connection?.cancel()
        connection  = nil
        buffer      = Data()
        sessionId   = nil
        cseq        = 0
        serverHost  = ""
        serverPort  = 48010
    }

    // MARK: - TCP connection

    private func connect(host: String, port: UInt16) async throws {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection = conn
        buffer = Data()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak conn] state in
                switch state {
                case .ready:
                    conn?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    conn?.stateUpdateHandler = nil
                    cont.resume(throwing: RTSPError.connectFailed(err.localizedDescription))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - Request / response

    private struct Response {
        let status:  Int
        let headers: [String: String]   // lowercase keys
        let body:    String?
    }

    private func request(_ method: String, uri: String,
                          extra: [String: String], body: Data? = nil) async throws -> Response {
        // Apollo closes the TCP socket after every response; open a fresh connection each time.
        connection?.cancel()
        try await connect(host: serverHost, port: serverPort)

        cseq += 1
        var msg = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        msg += "X-GS-ClientVersion: 14\r\n"
        if !serverHost.isEmpty { msg += "Host: \(serverHost)\r\n" }
        if let sid = sessionId { msg += "Session: \(sid)\r\n" }
        for (k, v) in extra   { msg += "\(k): \(v)\r\n" }
        msg += "\r\n"

        // Log outgoing request
        var reqBody = ""
        if let body, let bodyStr = String(data: body, encoding: .utf8) {
            reqBody = bodyStr
        }
        let reqHeader = ">>> \(method) (CSeq \(cseq))  \(uri)"
        let reqDetail = msg + (reqBody.isEmpty ? "" : "[body \(body!.count)B]\n\(reqBody)")
        rtspLogBlock(reqHeader, body: reqDetail, step: method)

        var raw = Data(msg.utf8)
        if let body { raw.append(body) }
        try await sendRaw(raw)

        let response: Response
        do {
            response = try await readResponse()
        } catch {
            rtspLog("ERROR reading response for \(method): \(error.localizedDescription)", step: method)
            throw error
        }

        // Log response
        var respDetail = "status: \(response.status)\n"
        for (k, v) in response.headers.sorted(by: { $0.key < $1.key }) {
            respDetail += "  \(k): \(v)\n"
        }
        if let body = response.body {
            respDetail += "[body \(body.utf8.count)B]\n\(body)"
        } else {
            respDetail += "[no body]"
        }
        rtspLogBlock("<<< \(method) → \(response.status)", body: respDetail, step: method)

        return response
    }

    private func readResponse() async throws -> Response {
        // Buffer data from the socket until we see the end of the header block.
        let headerEnd = Data("\r\n\r\n".utf8)
        while buffer.range(of: headerEnd) == nil {
            buffer.append(try await recvChunk())
        }

        let split = buffer.range(of: headerEnd)!
        let headerData = Data(buffer[..<split.upperBound])
        buffer = Data(buffer[split.upperBound...])

        guard let raw = String(data: headerData, encoding: .utf8) else {
            throw RTSPError.badResponse("non-UTF8 headers")
        }

        var lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw RTSPError.badResponse("empty response")
        }

        // "RTSP/1.0 200 OK"
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw RTSPError.badResponse("bad status line: \(statusLine)")
        }

        lines.removeFirst()
        var hdrs: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            hdrs[key] = val
        }

        var body: String? = nil
        if let lenStr = hdrs["content-length"], let len = Int(lenStr), len > 0 {
            // Standard path: Content-Length tells us exactly how many bytes to read.
            body = String(data: try await readBytes(len), encoding: .utf8)
        } else if !buffer.isEmpty {
            // Sunshine omits Content-Length and sends the SDP body immediately after
            // the headers in the same TCP segment. It will already be in our buffer.
            body = String(data: buffer, encoding: .utf8)
            buffer = Data()
        }

        return Response(status: code, headers: hdrs, body: body)
    }

    // MARK: - Socket I/O

    private func sendRaw(_ data: Data) async throws {
        guard let conn = connection else { throw RTSPError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else       { cont.resume() }
            })
        }
    }

    private func recvChunk() async throws -> Data {
        guard let conn = connection else { throw RTSPError.closed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error             { cont.resume(throwing: error);          return }
                if let data, !data.isEmpty { cont.resume(returning: data);        return }
                if isComplete            { cont.resume(throwing: RTSPError.closed) }
            }
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { buffer.append(try await recvChunk()) }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }

    // MARK: - SDP body builder

    /// Builds the client capability SDP sent in the ANNOUNCE body (after all SETUPs).
    /// Sunshine uses this to configure the encoder (resolution, FPS, bitrate, codec).
    /// Format mirrors Moonlight's SdpGenerator for AppVersion 7 / Sunshine.
    private func buildDescribeSDP(serverHost: String, videoLocalPort: UInt16,
                                   config: StreamConfig, encryptionEnabled: UInt32 = 1) -> String {
        let adjusted = min(Int(Double(config.bitrate) * 0.80), 100_000)
        let bitStreamFormat = switch config.codec {
            case .h264: 0
            case .hevc: 1
            case .av1:  2
        }
        let hevcFlag = config.codec == .hevc ? 1 : 0
        let refreshRateX100 = config.fps * 100

        func a(_ name: String, _ value: Any) -> String { "a=\(name):\(value) \r\n" }

        return
            "v=0\r\n" +
            "o=android 0 14 IN IPv4 \(serverHost)\r\n" +
            "s=NVIDIA Streaming Client\r\n" +
            "t=0 0\r\n" +
            "m=video \(videoLocalPort)  \r\n" +
            // Sunshine-specific feature negotiation
            a("x-ml-general.featureFlags",          3) +   // ML_FF_FEC_STATUS | ML_FF_SESSION_ID_V1
            a("x-ss-general.encryptionEnabled",     encryptionEnabled) +
            a("x-ss-video[0].chromaSamplingType",   0) +   // YUV 4:2:0
            // Stream geometry + encoder settings
            a("x-nv-video[0].clientViewportWd",     config.width) +
            a("x-nv-video[0].clientViewportHt",     config.height) +
            a("x-nv-video[0].maxFPS",               config.fps) +
            a("x-nv-video[0].packetSize",           Self.videoPacketSize) +
            a("x-nv-video[0].rateControlMode",      4) +
            a("x-nv-video[0].timeoutLengthMs",      7000) +
            a("x-nv-video[0].framesWithInvalidRefThreshold", 0) +
            // Bitrate
            a("x-nv-video[0].initialBitrateKbps",       adjusted) +
            a("x-nv-video[0].initialPeakBitrateKbps",   adjusted) +
            a("x-nv-vqos[0].bw.minimumBitrateKbps",     adjusted) +
            a("x-nv-vqos[0].bw.maximumBitrateKbps",     adjusted) +
            a("x-ml-video.configuredBitrateKbps",        config.bitrate) +
            // FEC + QoS (local)
            a("x-nv-vqos[0].fec.enable",                    1) +
            a("x-nv-vqos[0].videoQualityScoreUpdateTime",   5000) +
            a("x-nv-vqos[0].qosTrafficType",                5) +   // local
            a("x-nv-aqos.qosTrafficType",                   4) +   // local
            // Gen5 / Sunshine transport flags
            a("x-nv-general.featureFlags",          135) +  // NVFF_BASE(7) | NVFF_RI_ENCRYPTION(128)
            a("x-nv-general.useReliableUdp",        13) +  // 13 = encrypted ENet control stream (APP_VERSION >= 7.1.431)
            a("x-nv-vqos[0].fec.minRequiredFecPackets", 2) +
            a("x-nv-vqos[0].bllFec.enable",         0) +
            a("x-nv-vqos[0].drc.enable",            0) +
            a("x-nv-general.enableRecoveryMode",    0) +
            // Codec selection
            a("x-nv-video[0].videoEncoderSlicesPerFrame", 1) +
            a("x-nv-clientSupportHevc",             hevcFlag) +
            a("x-nv-vqos[0].bitStreamFormat",       bitStreamFormat) +
            a("x-nv-video[0].dynamicRangeMode",     config.hdr ? 1 : 0) +
            a("x-nv-video[0].maxNumReferenceFrames", 1) +
            a("x-nv-video[0].clientRefreshRateX100", refreshRateX100) +
            a("x-nv-video[0].encoderCscMode",       config.hdr ? 4 : 0) +   // 4=BT.2020 limited (HDR10), 0=BT.601 limited (SDR)
            // Audio (stereo)
            a("x-nv-audio.surround.numChannels",    2) +
            a("x-nv-audio.surround.channelMask",    3) +
            a("x-nv-audio.surround.enable",         0) +
            a("x-nv-audio.surround.AudioQuality",   0) +
            a("x-nv-aqos.packetDuration",           5)
    }

    // MARK: - Helpers

    /// Parse an SDP attribute "a=key:VALUE" from an SDP body, returning VALUE as UInt32 (or 0).
    private func sdpUInt(_ sdp: String, key: String) -> UInt32 {
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "a=\(key):"
            guard line.hasPrefix(prefix) else { continue }
            let val = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return UInt32(val) ?? 0
        }
        return 0
    }

    /// Session header value may be "12345;timeout=60" — return just the ID.
    private func sessionIDValue(from header: String) -> String {
        String(header.components(separatedBy: ";").first ?? header)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse "server_port=47998-47999" out of a Transport header.
    private func serverRTPPort(from transport: String, fallback: UInt16) -> UInt16 {
        for part in transport.components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix("server_port=") else { continue }
            let portPart = kv.dropFirst("server_port=".count)
            if let p = UInt16(portPart.components(separatedBy: "-").first ?? "") { return p }
        }
        return fallback
    }
}

// MARK: - SDP parser

private struct SDPInfo {
    let videoCodec:   VideoCodec
    let videoControl: String    // value of a=control: in the video section
    let audioControl: String    // value of a=control: in the audio section

    // Sunshine is AppVersion >= 5, so uses the /0/0 stream ID format.
    init() {
        videoCodec   = .h264
        videoControl = "streamid=video/0/0"
        audioControl = "streamid=audio/0/0"
    }

    init(_ sdp: String) {
        // Sunshine encodes HEVC with H264 MIME type — detect by VPS NALU base64 prefix.
        // AV1 does use its own MIME type.
        let codec: VideoCodec
        if sdp.contains("AV1/90000") {
            codec = .av1
        } else if sdp.contains("sprop-parameter-sets=AAAAAU") {
            codec = .hevc
        } else {
            codec = .h264
        }

        var videoCtrl  = "streamid=video/0/0"
        var audioCtrl  = "streamid=audio/0/0"
        var inVideo    = false
        var inAudio    = false

        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=video")      { inVideo = true;  inAudio = false }
            else if line.hasPrefix("m=audio") { inAudio = true;  inVideo = false }
            else if line.hasPrefix("a=control:") {
                let val = String(line.dropFirst("a=control:".count))
                if      inVideo { videoCtrl = val }
                else if inAudio { audioCtrl = val }
            }
        }

        videoCodec   = codec
        videoControl = videoCtrl
        audioControl = audioCtrl
    }
}

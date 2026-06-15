//
//  ENetClient.swift
//  ChloroFrame
//

import Foundation
import Network
import CryptoKit

// Minimal ENet client for Apollo/Sunshine's control stream.
//
// Apollo uses ENet on controlServerPort (default 47999).
// For Sunshine (useReliableUdp=13 / APP_VERSION >= 7.1.431), all control messages
// are wrapped in NVCTL_ENCRYPTED_PACKET_HEADER before being carried in ENet SEND_RELIABLE.
//
// Wire format of an encrypted control message (inside the ENet SEND_RELIABLE payload):
//
//   NVCTL_ENCRYPTED_PACKET_HEADER:
//     [LE16(0x0001)]              encryptedHeaderType
//     [LE16(4 + 16 + 4 + paylen)] length = sizeof(seq) + GCM_tag + NVCTL_V2_header + payload
//     [LE32(controlSeq)]          monotonically-increasing nonce seed
//   [16-byte AES-GCM tag]
//   [ciphertext of NVCTL_ENET_PACKET_HEADER_V2 + payload]:
//     [LE16(type)]                inner packet type (e.g. 0x0206 for input)
//     [LE16(paylen)]
//     [payload bytes]
//
// Nonce (12 bytes, SS_ENC_CONTROL_V2): [LE32(controlSeq)] [0x00 × 6] [0x43] [0x43]
// Key: rikey from the HTTP launch response.
//
// Reference: moonlight-common-c ControlStream.c — sendMessageEnet() + encryptControlMessage()

// MARK: - ENet protocol constants

private let ECMD_ACKNOWLEDGE:        UInt8 = 0x01
private let ECMD_CONNECT:            UInt8 = 0x02
private let ECMD_VERIFY_CONNECT:     UInt8 = 0x03
private let ECMD_DISCONNECT:         UInt8 = 0x04
private let ECMD_PING:               UInt8 = 0x05
private let ECMD_SEND_RELIABLE:      UInt8 = 0x06
private let ECMD_BANDWIDTH_LIMIT:    UInt8 = 0x0A
private let ECMD_THROTTLE_CONFIGURE: UInt8 = 0x0B
private let ECMD_FLAG_ACKNOWLEDGE:   UInt8 = 0x80

private let ENET_UNCONNECTED_PEER_ID: UInt16 = 0x0FFF
private let ENET_HEADER_FLAG_SENT_TIME: UInt16 = 0x8000

// MARK: - ENetClient

final class ENetClient {

    private enum State { case idle, connecting, connected }

    private var conn:  NWConnection?
    private var state: State = .idle

    // Set in VERIFY_CONNECT; used in all subsequent protocol headers.
    private var outgoingPeerID: UInt16 = ENET_UNCONNECTED_PEER_ID

    // Per-channel ENet reliable sequence counters (outbound).
    private var outSeq = [UInt8: UInt16]()

    // Outbound reliable packets awaiting ACK, keyed by (channel<<16 | seq). Retransmitted on a
    // timer until the host ACKs them. Without this, a single dropped control packet leaves a gap
    // in the host's in-order reliable channel that nothing fills, silently killing all input on
    // that channel until reconnect. sendQueue-confined.
    private struct PendingReliable {
        let channel: UInt8
        let seq:     UInt16
        let body:    [UInt8]
        var lastSentNanos: UInt64
        var retries: Int
    }
    private var pendingReliable: [UInt32: PendingReliable] = [:]
    private var retransmitTimer: DispatchSourceTimer?
    private static let reliableRtoNanos:   UInt64 = 100_000_000   // resend if unacked for 100 ms
    private static let reliableMaxRetries: Int    = 100           // ~10 s unacked ⇒ peer is dead

    // Pending connect continuation.
    private var connectCont: CheckedContinuation<Void, Error>?

    // Keepalive ping task.
    private var pingTask: Task<Void, Never>?

    // AES-GCM key and monotonically-increasing sequence number used as nonce seed.
    // Set before calling connect(). If nil, messages are sent plaintext (V1 header).
    var rikey: SymmetricKey?
    private var controlSeq: UInt32 = 0

    var onDisconnect: (() -> Void)?

    // All mutable send-path state (controlSeq, outSeq, NWConnection.send) is confined to
    // this queue. Callers on any thread (AppKit event callbacks, Swift concurrency tasks)
    // fire-and-forget into it; the queue serializes nonce increments and packet dispatch.
    private let sendQueue = DispatchQueue(label: "chloroframe.enet-send", qos: .userInteractive)

    // MARK: - Public API

    func connect(host: String, port: UInt16, connectData: UInt32) async throws {
        state = .connecting
        controlSeq = 0
        outSeq.removeAll()

        let ep = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        params.serviceClass = .responsiveData
        let c = NWConnection(to: ep, using: params)
        conn = c

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.stateUpdateHandler = { [weak self, weak c] s in
                switch s {
                case .ready:
                    c?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let e):
                    c?.stateUpdateHandler = nil
                    self?.state = .idle
                    cont.resume(throwing: e)
                default: break
                }
            }
            c.start(queue: .global(qos: .userInitiated))
        }
        startReceiveLoop()

        let connectPkt = buildConnect(connectData: connectData)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectCont = cont
            sendRaw(connectPkt)
        }

        pingTask = Task { [weak self] in await self?.pingLoop() }
    }

    /// Send a control-stream message over ENet.
    /// For the encrypted path (useReliableUdp=13), wraps in NVCTL_ENCRYPTED_PACKET_HEADER.
    /// For the plaintext path, sends a bare V1 header.
    /// Returns immediately; actual work (nonce increment, encrypt, send) runs on sendQueue.
    func sendControl(type: UInt16, payload: [UInt8], channel: UInt8 = 0) {
        guard state == .connected else { return }
        sendQueue.async { [weak self] in
            guard let self, self.state == .connected else { return }
            let body: [UInt8]
            if let key = self.rikey {
                body = self.encryptedControlBody(type: type, payload: payload, key: key)
            } else {
                body = self.le16(type) + payload
            }
            let seq = self.nextSeq(channel: channel)
            self.sendRaw(self.buildSendReliable(channel: channel, seq: seq, data: body))
            // Track until ACKed so a dropped packet gets retransmitted (see retransmitTick).
            let key = (UInt32(channel) << 16) | UInt32(seq)
            self.pendingReliable[key] = PendingReliable(
                channel: channel, seq: seq, body: body,
                lastSentNanos: DispatchTime.now().uptimeNanoseconds, retries: 0)
        }
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        // Drain the send queue so any packets queued just before disconnect (e.g. key-up
        // releases from InputHandler.releaseAll) are sent before we cancel the connection.
        sendQueue.sync {
            retransmitTimer?.cancel(); retransmitTimer = nil
            pendingReliable.removeAll()
            state  = .idle
            outgoingPeerID = ENET_UNCONNECTED_PEER_ID
            outSeq.removeAll()
            controlSeq = 0
        }
        conn?.cancel()
        conn   = nil
    }

    // MARK: - Encrypted packet builder (moonlight-common-c ControlStream.c translation)

    private func encryptedControlBody(type: UInt16, payload: [UInt8], key: SymmetricKey) -> [UInt8] {
        let seq = controlSeq
        controlSeq &+= 1

        // Plaintext = NVCTL_ENET_PACKET_HEADER_V2 + payload
        var plaintext = [UInt8]()
        plaintext += le16(type)
        plaintext += le16(UInt16(payload.count))
        plaintext += payload

        // Nonce (12 bytes, SS_ENC_CONTROL_V2):
        // bytes 0-3  = LE32(seq)
        // bytes 4-9  = 0x00
        // bytes 10-11 = 'C', 'C'  (client-to-host / control-stream marker)
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = UInt8(seq        & 0xFF)
        nonce[1] = UInt8((seq >>  8) & 0xFF)
        nonce[2] = UInt8((seq >> 16) & 0xFF)
        nonce[3] = UInt8((seq >> 24) & 0xFF)
        nonce[10] = 0x43   // 'C'
        nonce[11] = 0x43   // 'C'

        guard let gcmNonce = try? AES.GCM.Nonce(data: Data(nonce)),
              let sealed   = try? AES.GCM.seal(Data(plaintext), using: key, nonce: gcmNonce)
        else {
            return []
        }

        // NVCTL_ENCRYPTED_PACKET_HEADER:
        //   [LE16(0x0001)]              encryptedHeaderType
        //   [LE16(4 + 16 + 4 + paylen)] length
        //   [LE32(seq)]                  nonce seed (in wire LE order)
        // Followed by:
        //   [16-byte GCM tag]
        //   [ciphertext]
        let innerLen = UInt16(4 + 16 + 4 + payload.count)
        var out = [UInt8]()
        out += [0x01, 0x00]             // encryptedHeaderType = LE16(0x0001)
        out += le16(innerLen)           // length
        out += le32(seq)                // seq LE32
        out += Array(sealed.tag)        // 16-byte GCM tag
        out += Array(sealed.ciphertext) // ciphertext

        return out
    }

    // MARK: - Ping loop (0x0200 keepalive, 100 ms interval)

    private func pingLoop() async {
        while !Task.isCancelled {
            sendControl(type: 0x0200, payload: [])
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, err in
            guard let self else { return }
            // Dispatch all handling onto sendQueue so every mutation of ENetClient state
            // (state, outgoingPeerID, outSeq, controlSeq, sendRaw) happens on one queue.
            self.sendQueue.async { [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { self.handleDatagram([UInt8](data)) }
                if let err {
                    let wasConnected = self.state == .connected
                    let shouldReport = self.state != .idle || self.connectCont != nil
                    if shouldReport {
                        print("[ChloroFrame][enet] receive error: \(err)")
                    }
                    self.connectCont?.resume(throwing: err)
                    self.connectCont = nil
                    self.pingTask?.cancel()
                    self.pingTask = nil
                    self.state = .idle
                    if wasConnected {
                        self.onDisconnect?()
                    }
                } else {
                    self.startReceiveLoop()
                }
            }
        }
    }

    // MARK: - Datagram parser

    private func handleDatagram(_ b: [UInt8]) {
        var o = 0
        guard b.count >= 2 else { return }
        let rawID = be16(b, o); o += 2
        var remoteSentTime: UInt16 = 0
        if rawID & ENET_HEADER_FLAG_SENT_TIME != 0 {
            guard b.count >= 4 else { return }
            remoteSentTime = be16(b, o); o += 2
        }

        while o + 4 <= b.count {
            let rawCmd  = b[o]
            let cmd     = rawCmd & 0x0F
            let channel = b[o + 1]
            let seq     = be16(b, o + 2)
            o += 4

            switch cmd {
            case ECMD_ACKNOWLEDGE:
                guard o + 4 <= b.count else { return }
                // Body: receivedReliableSequenceNumber (2) + receivedSentTime (2). Clear the
                // matching tracked packet so it stops being retransmitted.
                let ackedSeq = be16(b, o)
                o += 4
                pendingReliable[(UInt32(channel) << 16) | UInt32(ackedSeq)] = nil

            case ECMD_VERIFY_CONNECT:
                guard o + 40 <= b.count else { return }
                let svrPeer = be16(b, o); o += 40
                outgoingPeerID = svrPeer
                state = .connected
                startRetransmitTimer()
                print("[ChloroFrame][enet] VERIFY_CONNECT ✓  ch=\(channel)  svrPeer=\(svrPeer)  encrypted=\(rikey != nil)")
                sendRaw(buildAck(channel: channel, seq: seq, remoteSentTime: remoteSentTime))
                connectCont?.resume()
                connectCont = nil

            case ECMD_SEND_RELIABLE:
                guard o + 2 <= b.count else { return }
                let len = Int(be16(b, o)); o += 2
                guard o + len <= b.count else { return }
                o += len
                sendRaw(buildAck(channel: channel, seq: seq, remoteSentTime: remoteSentTime))

            case ECMD_PING:
                sendRaw(buildAck(channel: channel, seq: seq, remoteSentTime: remoteSentTime))

            case ECMD_DISCONNECT:
                guard o + 4 <= b.count else { return }
                o += 4
                print("[ChloroFrame][enet] server sent DISCONNECT")
                pingTask?.cancel(); pingTask = nil
                retransmitTimer?.cancel(); retransmitTimer = nil
                pendingReliable.removeAll()
                conn?.cancel(); conn = nil
                state = .idle
                onDisconnect?()
                return

            case ECMD_BANDWIDTH_LIMIT:
                guard o + 8 <= b.count else { return }
                o += 8
                sendRaw(buildAck(channel: channel, seq: seq, remoteSentTime: remoteSentTime))

            case ECMD_THROTTLE_CONFIGURE:
                guard o + 12 <= b.count else { return }
                o += 12
                sendRaw(buildAck(channel: channel, seq: seq, remoteSentTime: remoteSentTime))

            default:
                return
            }
        }
    }

    // MARK: - Packet builders

    private func buildConnect(connectData: UInt32) -> Data {
        var d = Data()
        appendHeader(&d, peerID: ENET_UNCONNECTED_PEER_ID)
        d.append(ECMD_CONNECT | ECMD_FLAG_ACKNOWLEDGE)
        d.append(0xFF)
        append16BE(&d, 1)
        append16BE(&d, 0)               // outgoingPeerID
        d.append(0xFF)                  // incomingSessionID
        d.append(0xFF)                  // outgoingSessionID
        append32BE(&d, 1400)            // MTU
        append32BE(&d, 32768)           // windowSize
        append32BE(&d, 0x30)            // channelCount = 48
        append32BE(&d, 0)               // incomingBandwidth
        append32BE(&d, 0)               // outgoingBandwidth
        append32BE(&d, 5000)            // throttleInterval
        append32BE(&d, 2)               // throttleAcceleration
        append32BE(&d, 2)               // throttleDeceleration
        append32BE(&d, UInt32.random(in: 0..<UInt32.max))  // connectID
        append32BE(&d, connectData)
        return d
    }

    private func buildAck(channel: UInt8, seq: UInt16, remoteSentTime: UInt16) -> Data {
        var d = Data()
        appendHeader(&d, peerID: outgoingPeerID)
        d.append(ECMD_ACKNOWLEDGE)
        d.append(channel)
        append16BE(&d, 0)
        append16BE(&d, seq)
        append16BE(&d, remoteSentTime)
        return d
    }

    private func buildSendReliable(channel: UInt8, seq: UInt16, data: [UInt8]) -> Data {
        var d = Data()
        appendHeader(&d, peerID: outgoingPeerID)
        d.append(ECMD_SEND_RELIABLE | ECMD_FLAG_ACKNOWLEDGE)
        d.append(channel)
        append16BE(&d, seq)
        append16BE(&d, UInt16(data.count))
        d.append(contentsOf: data)
        return d
    }

    private func appendHeader(_ d: inout Data, peerID: UInt16) {
        let now = UInt16(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
        append16BE(&d, peerID | ENET_HEADER_FLAG_SENT_TIME)
        append16BE(&d, now)
    }

    // MARK: - Reliable retransmission (sendQueue only)

    private func startRetransmitTimer() {
        retransmitTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: sendQueue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50),
                   leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.retransmitTick() }
        t.resume()
        retransmitTimer = t
    }

    private func retransmitTick() {
        guard state == .connected, !pendingReliable.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        for key in Array(pendingReliable.keys) {
            guard var p = pendingReliable[key],
                  now &- p.lastSentNanos >= Self.reliableRtoNanos else { continue }
            if p.retries >= Self.reliableMaxRetries {
                print("[ChloroFrame][enet] reliable ch=\(p.channel) seq=\(p.seq) unacked after \(p.retries) retries — peer dead, disconnecting")
                pendingReliable.removeAll()
                retransmitTimer?.cancel(); retransmitTimer = nil
                conn?.cancel(); conn = nil
                state = .idle
                onDisconnect?()
                return
            }
            // Rebuild so the header carries a fresh sent-time; the seq is unchanged so the host
            // fills the gap (or de-dupes if the original arrived but its ACK was lost).
            sendRaw(buildSendReliable(channel: p.channel, seq: p.seq, data: p.body))
            p.lastSentNanos = now
            p.retries += 1
            pendingReliable[key] = p
        }
    }

    // MARK: - Helpers

    private func nextSeq(channel: UInt8) -> UInt16 {
        let s = (outSeq[channel] ?? 0) &+ 1
        outSeq[channel] = s
        return s
    }

    private func sendRaw(_ data: Data) {
        conn?.send(content: data, completion: .idempotent)
    }

    private func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func append16BE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xFF))
    }

    private func append32BE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >>  8) & 0xFF))
        d.append(UInt8( v        & 0xFF))
    }
}

//
//  RTPAudioReceiver.swift
//  ChloroFrame
//
//  Thin UDP receiver for the Sunshine audio stream.
//  Responsibilities:
//    - Bind a UDP socket, send SS_PING keepalives every 500 ms
//    - Parse 12-byte RTP header and produce NetworkAudioPacket
//    - Drop duplicates (same seq#) and non-data payload types
//    - Pass packets to `onPacket` (called on the NW receive queue)
//
//  No decode, no AVAudioEngine — that lives in AudioEngine.

import Foundation
import Network
import Synchronization

private let rlog = NoopLog()

final class RTPAudioReceiver {

    /// Deliver each parsed RTP data packet to this closure.
    /// Called on the internal NW receive queue — dispatch to your own queue if needed.
    var onPacket: ((NetworkAudioPacket) -> Void)?

    private var conn:     NWConnection?
    private var pingTask: Task<Void, Never>?

    private var lastSeqSeen:       UInt16? = nil
    private var firstPacketLogged: Bool    = false

    // Diagnostics: distinguish true loss from reordering. Both written only on the NW
    // receive queue (single writer); Atomic for cross-thread reads at snapshot time.
    //   apparentLoss      — forward sequence gaps (seq jumped by >1): packets that never
    //                       arrived *in order*. Reordering inflates this too (see below).
    //   reorderDiscarded  — packets we drop because seq went backwards (delta <= 0): late
    //                       or duplicate arrivals. A reordered packet shows up as BOTH a
    //                       forward gap (when its successor arrives first) AND a discard,
    //                       so apparentLoss ≈ reorderDiscarded means reordering, not loss.
    private let _apparentLoss     = Atomic<Int>(0)
    private let _reorderDiscarded = Atomic<Int>(0)
    var apparentLoss:     Int { _apparentLoss.load(ordering: .relaxed) }
    var reorderDiscarded: Int { _reorderDiscarded.load(ordering: .relaxed) }

    enum ReceiverError: Error {
        case cancelled
    }

    // MARK: - Lifecycle

    /// Binds the UDP socket and sends the first SS_PING before returning.
    /// Callers must await this so Start A/B is sent only after the socket is ready.
    /// - Parameter requiredInterface: when non-nil, pins the socket to this interface (used to
    ///   keep media off awdl0 when Wi-Fi is actually the route to the host). nil means do not
    ///   pin — the route goes elsewhere (VPN, Ethernet, ...) and forcing it onto Wi-Fi would
    ///   send packets nowhere. See RouteResolver / design/tailscale-connection-fix-plan.md.
    /// - Parameter family: AF_INET or AF_INET6, from the resolved route. Selects the wildcard
    ///   local endpoint address; defaults to AF_INET so existing IPv4-only callers are
    ///   unaffected.
    func start(host: String, serverPort: UInt16, localPort: UInt16, pingPayload: String,
               requiredInterface: NWInterface? = nil, family: Int32 = AF_INET) async throws {
        rlog.info("receiver start localPort=\(localPort) serverPort=\(serverPort)")

        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        let wildcardHost: NWEndpoint.Host = family == AF_INET6 ? .init("::") : .init("0.0.0.0")
        params.requiredLocalEndpoint = .hostPort(
            host: wildcardHost,
            port: .init(rawValue: localPort)!
        )
        // macOS pins the audio socket to the caller-resolved interface (only when it's
        // actually Wi-Fi, see the requiredInterface doc comment above) so replies can't route
        // over awdl0. tvOS drops interface discovery (port plan 6.4), removing the
        // NetworkMonitor dependency from the tvOS build.
        #if os(macOS)
        if let requiredInterface {
            params.requiredInterface = requiredInterface
        }
        #endif

        let c = NWConnection(
            to: .hostPort(host: .init(host), port: .init(rawValue: serverPort)!),
            using: params
        )
        conn = c

        // Await the socket reaching .ready so the caller knows the port is bound
        // before sending Start A/B (which triggers the server to begin streaming).
        // A path that never satisfies (e.g. requiredInterface has no route to the
        // destination) surfaces as .waiting and would otherwise hang here forever — give it
        // a short grace period in case it's transient (interface still coming up), then fail.
        //
        // resumeOnce always hops onto resolveQueue (a dedicated serial queue) before touching
        // `resumed`, so the flag is single-queue-confined even though it can be set from two
        // independent triggers: NWConnection's own callback stream (serialized by NWConnection
        // onto whatever queue c.start(queue:) was given) and the timeout DispatchWorkItem
        // (scheduled on resolveQueue directly). Without this, a state-change resume racing the
        // timeout's read-modify-write of `resumed` would be a real data race, not just
        // theoretical — the two run on genuinely different execution contexts.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let resolveQueue = DispatchQueue(label: "chloroframe.audiorx.connect-resolve")
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                resolveQueue.async {
                    guard !resumed else { return }
                    resumed = true
                    switch result {
                    case .success:        cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
            var waitingWorkItem: DispatchWorkItem?
            c.stateUpdateHandler = { [weak self, weak c] state in
                switch state {
                case .ready:
                    waitingWorkItem?.cancel()
                    c?.stateUpdateHandler = nil
                    rlog.info("UDP socket ready")
                    self?.startReceive()
                    self?.startPing(payload: pingPayload)
                    resumeOnce(.success(()))
                case .failed(let err):
                    waitingWorkItem?.cancel()
                    rlog.error("UDP socket failed: \(err)")
                    c?.stateUpdateHandler = nil
                    resumeOnce(.failure(err))
                case .waiting(let err):
                    guard waitingWorkItem == nil else { break }
                    rlog.error("UDP socket waiting: \(err) — will fail if unresolved in 3s")
                    let work = DispatchWorkItem { [weak c] in
                        c?.cancel()
                        resumeOnce(.failure(err))
                    }
                    waitingWorkItem = work
                    resolveQueue.asyncAfter(deadline: .now() + 3, execute: work)
                case .cancelled:
                    waitingWorkItem?.cancel()
                    resumeOnce(.failure(ReceiverError.cancelled))
                default: break
                }
            }
            c.start(queue: .global(qos: .userInteractive))
        }
    }

    func stop() {
        pingTask?.cancel()
        conn?.cancel()
        conn     = nil
        pingTask = nil
        lastSeqSeen       = nil
        firstPacketLogged = false
        _apparentLoss.store(0, ordering: .relaxed)
        _reorderDiscarded.store(0, ordering: .relaxed)
    }

    // MARK: - Receive loop

    private func startReceive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, err in
            if let data { self?.handleDatagram(data) }
            if err == nil { self?.startReceive() }
        }
    }

    private func handleDatagram(_ data: Data) {
        guard data.count > 12 else { return }

        let pt = data[1] & 0x7F

        if !firstPacketLogged {
            rlog.info("first datagram len=\(data.count) PT=\(pt)")
            firstPacketLogged = true
        }

        // PT 127 = FEC (4+2 Cauchy shards) — deferred; drop silently.
        // PT 97  = Opus data — process.
        guard pt == 97 else { return }

        let seq = UInt16(data[2]) << 8 | UInt16(data[3])

        // Drop duplicates/reordered. Use signed delta (RFC 3550 §A.1) so wrap-around is
        // handled: a packet is a duplicate or backwards retransmission if delta <= 0.
        if let last = lastSeqSeen {
            let delta = Int16(bitPattern: seq &- last)
            if delta <= 0 {
                // Late or duplicate arrival — currently discarded.
                _reorderDiscarded.store(_reorderDiscarded.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
                return
            }
            if delta > 1 {
                // Forward gap: (delta - 1) sequence numbers skipped (PT 97 seq is contiguous).
                _apparentLoss.store(_apparentLoss.load(ordering: .relaxed) &+ Int(delta - 1), ordering: .relaxed)
            }
        }
        lastSeqSeen = seq

        let rtp  = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        let arrival = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        let packet = NetworkAudioPacket(
            sequenceNumber:    seq,
            rtpTimestamp:      rtp,
            localArrivalNanos: arrival,
            payload:           data.dropFirst(12)
        )
        onPacket?(packet)
    }

    // MARK: - SS_PING outbound

    private func startPing(payload: String) {
        pingTask = Task { [weak self] in
            var seq: UInt32 = 0
            while !Task.isCancelled {
                if let d = self?.makePing(payload: payload, seq: seq) {
                    self?.conn?.send(content: d, completion: .idempotent)
                }
                seq &+= 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
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
}

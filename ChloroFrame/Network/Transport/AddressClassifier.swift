//
//  AddressClassifier.swift
//  ChloroFrame
//
//  Classifies a numeric host address as local or remote, matching moonlight-common-c's
//  isPrivateNetworkAddress (PlatformSockets.c), the same rule Apollo/Sunshine's own remote-
//  stream detection uses, so the client's classification agrees with what the host assumes.
//
//  IPv4 local: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8.
//  100.64.0.0/10 (CGNAT, including Tailscale) is deliberately REMOTE: moonlight passes
//  matchCGN: false for its own-address checks, so a Tailscale IPv4 address is treated as if it
//  were reached over the open internet (smaller packets, remote QoS/bitrate).
//  IPv6 local: fe80::/10, fec0::/10, fc00::/7 (covers Tailscale's fd7a:.../48 ULA range), ::1.
//
//  Also owns PacketSizePolicy: the video packet size negotiated in ANNOUNCE, which must never
//  exceed the actual route's MTU or every video datagram gets IP-fragmented. See
//  design/tailscale-connection-fix-plan.md Phase 2.
//

import Foundation

nonisolated enum StreamNetworkClass: Sendable {
    case local, remote
}

nonisolated enum AddressClassifier {

    /// Classifies a numeric (already-resolved) host address. Anything that isn't a parseable
    /// IPv4/IPv6 literal (a hostname slipped through, or malformed input) defaults to remote:
    /// the safer wrong guess is smaller packets, not risking IP fragmentation.
    static func classify(numericHost: String) -> StreamNetworkClass {
        var v4 = in_addr()
        if inet_pton(AF_INET, numericHost, &v4) == 1 {
            return isPrivateV4(v4) ? .local : .remote
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, numericHost, &v6) == 1 {
            return isPrivateV6(v6) ? .local : .remote
        }
        return .remote
    }

    // MARK: - IPv4

    private static func isPrivateV4(_ addr: in_addr) -> Bool {
        let a = UInt32(bigEndian: addr.s_addr)
        if (a & 0xFF000000) == 0x0A000000 { return true }   // 10.0.0.0/8
        if (a & 0xFFF00000) == 0xAC100000 { return true }   // 172.16.0.0/12
        if (a & 0xFFFF0000) == 0xC0A80000 { return true }   // 192.168.0.0/16
        if (a & 0xFFFF0000) == 0xA9FE0000 { return true }   // 169.254.0.0/16
        if (a & 0xFF000000) == 0x7F000000 { return true }   // 127.0.0.0/8
        return false   // notably: 100.64.0.0/10 (CGNAT/Tailscale) is NOT private here
    }

    // MARK: - IPv6

    private static func isPrivateV6(_ addr: in6_addr) -> Bool {
        var a = addr
        let b = withUnsafeBytes(of: &a) { Array($0.bindMemory(to: UInt8.self)) }
        if b == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }   // ::1
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                  // fe80::/10
        if b[0] == 0xFE && (b[1] & 0xC0) == 0xC0 { return true }                  // fec0::/10
        if (b[0] & 0xFE) == 0xFC { return true }                                  // fc00::/7
        return false
    }
}

nonisolated enum PacketSizePolicy {

    /// Video packet size (bytes after the RTP header, matching Moonlight's StreamConfig.
    /// packetSize) to advertise in ANNOUNCE. Starts from Moonlight's own local/remote defaults,
    /// then caps to whatever the resolved route's MTU can actually carry without fragmenting
    /// (needed for Tailscale IPv6, which classifies as local/ULA but still rides a
    /// sub-1500-MTU tunnel).
    static func choose(class networkClass: StreamNetworkClass, family: Int32, interfaceMTU: Int?) -> Int {
        var size = 1392
        if networkClass == .remote {
            size = (family == AF_INET6) ? 1184 : 1024   // moonlight Connection.c remote caps
        }
        if let mtu = interfaceMTU {
            let ipHeader = (family == AF_INET6) ? 40 : 20
            let cap = (mtu - ipHeader - 8 /* UDP */ - 16 /* RTP */) & ~15   // keep a multiple of 16
            size = min(size, cap)
        }
        return size
    }
}

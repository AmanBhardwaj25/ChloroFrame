//
//  RouteResolver.swift
//  ChloroFrame
//
//  Asks the kernel which network interface an UNPINNED socket would use to reach a given
//  host:port, without sending any data. StreamTransport uses this to decide whether to pin
//  the video/audio sockets to Wi-Fi: pinning is only correct when Wi-Fi is actually the route
//  to the host. Pinning unconditionally (the old behavior) sends Tailscale/VPN/Ethernet
//  traffic out the Wi-Fi interface instead, where it has no route to the destination and
//  falls back to the LAN default gateway. See design/tailscale-connection-fix-plan.md.
//
//  connect() on a UDP socket sends no packets — it only asks the kernel to pick a route and a
//  source address for that destination, which is exactly the question we need answered.
//

import Foundation
import Darwin

/// What RouteResolver learned about the path to a host: which address the kernel would
/// actually send to, over which interface, and that interface's MTU.
nonisolated struct RouteInfo: Equatable, Sendable {
    let destination:    String   // numeric host actually used (getnameinfo NI_NUMERICHOST)
    let family:         Int32    // AF_INET or AF_INET6
    let interfaceName:  String   // "en0", "utun5", "en7", ...
    let interfaceIndex: UInt32   // if_nametoindex(interfaceName)
    let interfaceMTU:   Int?     // SIOCGIFMTU; nil if unreadable
}

nonisolated enum RouteResolver {

    /// Resolves `host`, connects a throwaway UDP socket to (host, port), and reads back which
    /// local address/interface the kernel chose for that route. Blocking (getaddrinfo may do
    /// DNS) — call from a detached task, never on the main actor. Returns nil on any failure
    /// (fail open: the caller should treat that as "route unknown, do not pin").
    static func resolve(host: String, port: UInt16) -> RouteInfo? {
        let cleanHost = stripBrackets(host)

        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(cleanHost, String(port), &hints, &resolved) == 0, let addrInfo = resolved else {
            return nil
        }
        defer { freeaddrinfo(addrInfo) }

        let family = addrInfo.pointee.ai_family
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard Darwin.connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen) == 0 else {
            return nil
        }

        guard let destination = numericHost(of: addrInfo.pointee.ai_addr, len: addrInfo.pointee.ai_addrlen) else {
            return nil
        }

        var localAddr = sockaddr_storage()
        var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let sockNameStatus = withUnsafeMutablePointer(to: &localAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &localLen)
            }
        }
        guard sockNameStatus == 0 else { return nil }

        guard let ifaceName = interfaceName(forLocalAddress: &localAddr, family: family) else {
            return nil
        }

        let index = if_nametoindex(ifaceName)
        guard index != 0 else { return nil }

        return RouteInfo(
            destination: destination,
            family: family,
            interfaceName: ifaceName,
            interfaceIndex: index,
            interfaceMTU: readMTU(interfaceName: ifaceName)
        )
    }

    // MARK: - Helpers

    private static func stripBrackets(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("["), h.hasSuffix("]") {
            h.removeFirst()
            h.removeLast()
        }
        return h
    }

    private static func numericHost(of addr: UnsafeMutablePointer<sockaddr>?, len: socklen_t) -> String? {
        guard let addr else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = buf.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            getnameinfo(addr, len, bufPtr.baseAddress, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
        }
        guard status == 0 else { return nil }
        return String(cString: buf)
    }

    /// Walks getifaddrs() looking for the interface whose address matches the kernel-chosen
    /// local address for our connected socket.
    private static func interfaceName(forLocalAddress local: inout sockaddr_storage, family: Int32) -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, Int32(addr.pointee.sa_family) == family else { continue }

            let matches = withUnsafePointer(to: &local) { localPtr in
                addressesMatch(candidate: addr, want: localPtr, family: family)
            }
            if matches {
                return String(cString: ifa.pointee.ifa_name)
            }
        }
        return nil
    }

    private static func addressesMatch(
        candidate: UnsafeMutablePointer<sockaddr>,
        want: UnsafePointer<sockaddr_storage>,
        family: Int32
    ) -> Bool {
        if family == AF_INET {
            return candidate.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { c in
                want.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { w in
                    c.pointee.sin_addr.s_addr == w.pointee.sin_addr.s_addr
                }
            }
        } else if family == AF_INET6 {
            return candidate.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { c in
                want.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { w in
                    var cAddr = c.pointee.sin6_addr
                    var wAddr = w.pointee.sin6_addr
                    return memcmp(&cAddr, &wAddr, MemoryLayout<in6_addr>.size) == 0
                }
            }
        }
        return false
    }

    // SIOCGIFMTU = _IOWR('i', 51, struct ifreq); not exposed as a Swift constant on Darwin.
    // Same encoding pattern as AWDLSuppressor's kSIOCGIFFLAGS (0xC0206911 = _IOWR('i', 17, ifreq)).
    private static let siocgifmtu: UInt = 0xC0206933

    /// Best-effort interface MTU via SIOCGIFMTU on a throwaway AF_INET socket — an
    /// unprivileged read, same pattern as AWDLSuppressor.isAWDLActive's SIOCGIFFLAGS read.
    private static func readMTU(interfaceName: String) -> Int? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var ifr = ifreq()
        withUnsafeMutablePointer(to: &ifr.ifr_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) {
                _ = strncpy($0, interfaceName, Int(IFNAMSIZ) - 1)
            }
        }
        guard withUnsafeMutablePointer(to: &ifr, { Darwin.ioctl(fd, siocgifmtu, $0) }) == 0 else { return nil }
        return Int(ifr.ifr_ifru.ifru_mtu)
    }
}

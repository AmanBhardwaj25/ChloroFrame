//
//  HostAddress.swift
//  ChloroFrame
//
//  Normalizes and formats host address strings so IPv6 literals work everywhere an address is
//  typed, saved, or built into a URL/header/SDP line. See design/tailscale-connection-fix-
//  plan.md Phase 3.
//
//  The rest of the streaming pipeline (RouteResolver, RTSPClient, RTPVideoReceiver,
//  RTPAudioReceiver, ENetClient) works with the UNBRACKETED literal throughout — that's what
//  getaddrinfo/inet_pton/NWEndpoint.Host all expect, and it's what URL.host() already hands
//  back for an IPv6 session URL. Brackets are only needed at the few points that build literal
//  URL or header syntax, which is what urlHost(_:) is for.
//

import Foundation

nonisolated enum HostAddress {

    /// Trims whitespace and strips surrounding brackets, for storing a user-typed address.
    /// "[fd7a::1]" and "fd7a::1" both normalize to "fd7a::1"; IPv4 addresses and hostnames pass
    /// through unchanged.
    static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }

    /// Bracket-wraps an IPv6 literal for use as a URL host or SDP "o=" address
    /// ("fd7a::1" -> "[fd7a::1]"); IPv4 addresses and hostnames pass through unchanged.
    /// Idempotent: normalizes first, so calling this on an already-bracketed input is safe.
    static func urlHost(_ raw: String) -> String {
        let s = normalized(raw)
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return "[\(s)]"
        }
        return s
    }
}

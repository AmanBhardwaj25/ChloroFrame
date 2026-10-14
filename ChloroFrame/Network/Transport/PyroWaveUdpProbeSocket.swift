//
//  PyroWaveUdpProbeSocket.swift
//  ChloroFrame
//
//  The receiving half of the PyroWave UDP network test (D7b). A throwaway UDP socket with the
//  same options as RTPVideoReceiver (service type, optional Wi-Fi pinning, large receive
//  buffer), a receive thread that timestamps every datagram, and the token send that completes
//  the host's handshake. It never connect()s: the host sends from a port it picks itself, and
//  the token in each payload is what authenticates a datagram.
//

import Foundation
import Darwin
import os

nonisolated final class PyroWaveUdpProbeSocket: @unchecked Sendable {

    enum SocketError: Error, Equatable {
        case createFailed(Int32)
        case bindFailed(Int32)
        case resolveFailed(String)
    }

    private let fd: Int32
    private let family: Int32
    let localPort: UInt16
    private let stopFlag = OSAllocatedUnfairLock(initialState: false)
    private let collector: OSAllocatedUnfairLock<PyroWaveUdpProbeCollector>
    private let finished = DispatchSemaphore(value: 0)
    private var started = false

    /// Binds an ephemeral port. `pinInterfaceIndex` pins to Wi-Fi exactly like the stream socket
    /// does (only when Wi-Fi is the route; nil leaves the socket unpinned).
    init(token: String, family: Int32, pinInterfaceIndex: UInt32?) throws {
        self.family = family
        collector = OSAllocatedUnfairLock(initialState: PyroWaveUdpProbeCollector(token: token))

        let s = socket(family, SOCK_DGRAM, 0)
        guard s >= 0 else { throw SocketError.createFailed(errno) }
        var ok = false
        defer { if !ok { close(s) } }

        // About 500 KB per 2 s of probe at 250 Mbps arrives in bursts; 4 MB is ample.
        var rcvBuf: Int32 = 4 * 1024 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        var serviceType: Int32 = NET_SERVICE_TYPE_VI
        setsockopt(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))
        if var index = pinInterfaceIndex {
            if family == AF_INET6 {
                setsockopt(s, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            } else {
                setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        var storage = sockaddr_storage()
        var length = socklen_t(0)
        if family == AF_INET6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_addr = in6addr_any
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeBytes(of: &a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = INADDR_ANY
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeBytes(of: &a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, length) }
        }
        guard bound == 0 else { throw SocketError.bindFailed(errno) }

        var local = sockaddr_storage()
        var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &localLength) }
        }
        guard named == 0 else { throw SocketError.bindFailed(errno) }
        let port: UInt16 = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        // sockaddr_in and sockaddr_in6 keep the port at the same offset.
        guard port != 0 else { throw SocketError.bindFailed(0) }
        fd = s
        localPort = port
        ok = true
    }

    deinit {
        if !started { close(fd) }
    }

    /// Starts the timestamping receive thread. Call once.
    func startReceiving() {
        started = true
        let fd = self.fd
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !stopFlag.withLock({ $0 }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 20)
                if ready <= 0 { continue }
                while true {
                    let n = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
                    if n < 0 { break }
                    let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000
                    buffer.withUnsafeBytes { raw in
                        collector.withLock { _ = $0.ingest(UnsafeRawBufferPointer(rebasing: raw[0..<n]), atMs: ms) }
                    }
                }
            }
            close(fd)
            finished.signal()
        }
        thread.name = "chloroframe.pyrowave-probe-rx"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Sends the 32 byte token (nothing else) to `host:port` from this socket.
    func sendToken(_ token: String, to host: String, port: UInt16) throws {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: family, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let info = resolved else {
            throw SocketError.resolveFailed(host)
        }
        defer { freeaddrinfo(info) }
        let bytes = Array(token.utf8)
        _ = bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen) }
    }

    /// True once a measured probe packet has arrived (the handshake is complete).
    var hasData: Bool { collector.withLock { !$0.arrivals.isEmpty } }

    /// Stops the receive thread, closes the socket and returns what was collected.
    func finish() -> PyroWaveUdpProbeCollector {
        stopFlag.withLock { $0 = true }
        if started { finished.wait() }
        return collector.withLock { $0 }
    }
}

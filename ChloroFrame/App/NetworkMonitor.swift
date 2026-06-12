//
//  NetworkMonitor.swift
//  ChloroFrame
//

import Foundation
import Network

// Persistent NWPathMonitor that caches the active WiFi interface.
// Started once at app launch so RTPVideoReceiver.start() can read
// the interface immediately with no blocking or semaphore wait.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    // Written and read on the main thread (monitor runs on .main queue).
    private(set) var wifiInterface: NWInterface?
    private var monitor: NWPathMonitor?

    private init() {}

    func start() {
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { [weak self] path in
            self?.wifiInterface = path.availableInterfaces.first { $0.type == .wifi }
        }
        m.start(queue: .main)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        wifiInterface = nil
    }
}

//
//  HostManager.swift
//  ChloroFrame
//
//  Shared host model and persistence, split out of ContentView.swift so both the
//  macOS and tvOS targets can use it. SunshineHTTPClient takes a Host, so this has
//  to be reachable by any target that talks to a host. Framework-free (Foundation +
//  Observation only); no AppKit/UIKit.
//

import Foundation
import Observation

// MARK: - Model

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var port: UInt16 = 47989
}

// MARK: - Host Manager

@Observable
class HostManager {
    var hosts: [Host] = []
    var isScanning = false

    private let storageKey = "chloroframe.hosts"

    init() { load() }

    func add(name: String, address: String, port: UInt16) {
        hosts.append(Host(name: name, address: address, port: port))
        persist()
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    func scanLocalNetwork() {
        guard !isScanning else {
            print("[HostManager] scanLocalNetwork: already scanning — ignored")
            return
        }
        print("[HostManager] scanLocalNetwork: starting scan (mDNS/Bonjour not yet implemented)")
        isScanning = true
        // TODO: mDNS/Bonjour discovery — replace the timeout stub below with NWBrowser
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            print("[HostManager] scanLocalNetwork: stub timeout elapsed, scan complete (0 hosts found)")
            self?.isScanning = false
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([Host].self, from: data) else { return }
        hosts = saved
    }
}

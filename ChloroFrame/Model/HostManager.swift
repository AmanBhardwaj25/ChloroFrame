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

// nonisolated: pure value data (used by SunshineHTTPClient off the main actor, and decoded/
// encoded directly in unit tests) with no MainActor-specific behavior of its own. Without this,
// the app target's default MainActor isolation (SWIFT_DEFAULT_ACTOR_ISOLATION) makes Host's
// synthesized Codable conformance MainActor-isolated too, which the test target (no such
// default) can't use from a plain nonisolated test method.
nonisolated struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    // Optional fallback address (e.g. a Tailscale/VPN address for the same PC), tried if the
    // primary doesn't respond. Must stay Optional with an explicit `= nil` default, not a
    // defaulted String — Swift's synthesized Decodable does not honor a property's default
    // value for a missing JSON key, only Optional does, so a non-optional field here would fail
    // to decode every host saved before this existed. The `= nil` also keeps the synthesized
    // memberwise initializer treating it as omittable. See design/tailscale-connection-fix-
    // plan.md Phase 6.
    var secondaryAddress: String? = nil
    var port: UInt16 = 47989
}

// MARK: - Host Manager

@Observable
class HostManager {
    var hosts: [Host] = []
    var isScanning = false

    private let storageKey = "chloroframe.hosts"

    init() { load() }

    func add(_ host: Host) {
        hosts.append(host)
        persist()
    }

    // Convenience overload for callers that don't build a Host directly (TVContentView).
    func add(name: String, address: String, port: UInt16) {
        add(Host(name: name, address: address, port: port))
    }

    func update(_ host: Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
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

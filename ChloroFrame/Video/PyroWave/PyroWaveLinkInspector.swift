//
//  PyroWaveLinkInspector.swift
//  ChloroFrame
//
//  Facts about this Mac's side of the route (design/pyrowave-implementation-plan.md D5b, C6 and
//  C7): is the interface Ethernet or Wi-Fi, which Wi-Fi band, and the link or PHY rate.
//
//  Wi-Fi is checked first because macOS reports Wi-Fi interfaces as IFT_ETHER in getifaddrs too.
//  Since macOS 14 some CoreWLAN properties (SSID/BSSID) are nil without Location Services
//  permission. ChloroFrame does not ask for it; when the band comes back unknown the audit
//  reports a soft warning, never a block.
//

import Foundation
import CoreWLAN
import Darwin

nonisolated enum PyroWaveLinkInspector {

    /// Blocking (CoreWLAN and getifaddrs); call from a detached task, never on the main actor.
    static func inspect(interfaceName: String) -> PyroWaveMacLink {
        if let wifi = CWWiFiClient.shared().interfaceNames(), wifi.contains(interfaceName) {
            let iface = CWWiFiClient.shared().interface(withName: interfaceName)
            return PyroWaveMacLink(
                interfaceName: interfaceName,
                kind: .wifi,
                wifiBand: iface?.wlanChannel().flatMap { band(from: $0.channelBand) },
                linkMbps: iface.flatMap { phyRate($0.transmitRate()) }
            )
        }
        if let link = linkLevelInfo(interfaceName: interfaceName) {
            if link.type == UInt8(IFT_ETHER) {
                // ifi_baudrate is bit/s (a UInt32, so it tops out near 4.29 Gbit/s). USB
                // adapters may report 0, which the audit treats as unknown.
                let mbps = Int(link.baudrate / 1_000_000)
                return PyroWaveMacLink(interfaceName: interfaceName, kind: .ethernet,
                                       linkMbps: mbps > 0 ? mbps : nil)
            }
        }
        return PyroWaveMacLink(interfaceName: interfaceName, kind: .other)
    }

    // MARK: - Helpers

    private static func band(from band: CWChannelBand) -> PyroWaveWiFiBand? {
        switch band {
        case .band2GHz: return .ghz2_4
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default:        return nil
        }
    }

    /// CoreWLAN reports 0 when not associated or when it cannot read the rate.
    private static func phyRate(_ mbps: Double) -> Int? {
        mbps > 0 ? Int(mbps.rounded()) : nil
    }

    private static func linkLevelInfo(interfaceName: String) -> (type: UInt8, baudrate: UInt32)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_LINK,
                  String(cString: ifa.pointee.ifa_name) == interfaceName,
                  let raw = ifa.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return (data.ifi_type, data.ifi_baudrate)
        }
        return nil
    }
}

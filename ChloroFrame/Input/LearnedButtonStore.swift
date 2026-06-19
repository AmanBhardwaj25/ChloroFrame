//
//  LearnedButtonStore.swift
//  ChloroFrame
//
//  User-labeled "extra" buttons that GameController does not expose, captured at the raw-HID
//  level through the learn flow (see controller-mapping.md §3). Each is identified by where its
//  bit lives in the device's input report, and given a distinct user label so it can be bound
//  like any known button.
//
//  Learned buttons are DEVICE-SCOPED: the byte/bit offsets are specific to one controller's
//  report format (on the Flydigi the four paddles are bits on report 0, byte 19), so they are
//  keyed by vendorID + productID and only apply to that controller model.
//
//  Storage: UserDefaults, JSON, as [deviceKey: [LearnedButton]].
//

import Foundation

struct LearnedButton: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var reportID: Int
    var byteIndex: Int
    var bitmask: UInt8

    /// Stable key for "this exact bit", used to skip bits the user has already learned.
    var bitKey: String { "\(reportID):\(byteIndex):\(bitmask)" }
}

struct LearnedButtonStore {
    private static let defaultsKey = "controllerLearnedButtons"

    /// Device key from a controller's USB vendor/product IDs.
    static func deviceKey(vendorID: Int, productID: Int) -> String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    static func load(deviceKey: String, _ defaults: UserDefaults = .standard) -> [LearnedButton] {
        loadAll(defaults)[deviceKey] ?? []
    }

    static func save(_ buttons: [LearnedButton], deviceKey: String, _ defaults: UserDefaults = .standard) {
        var all = loadAll(defaults)
        if buttons.isEmpty { all.removeValue(forKey: deviceKey) } else { all[deviceKey] = buttons }
        if all.isEmpty { defaults.removeObject(forKey: defaultsKey) }
        else if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: defaultsKey) }
    }

    private static func loadAll(_ defaults: UserDefaults) -> [String: [LearnedButton]] {
        guard let data = defaults.data(forKey: defaultsKey),
              let all = try? JSONDecoder().decode([String: [LearnedButton]].self, from: data) else { return [:] }
        return all
    }
}

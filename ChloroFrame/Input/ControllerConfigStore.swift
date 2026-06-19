//
//  ControllerConfigStore.swift
//  ChloroFrame
//
//  Per-controller configuration, stored as a JSON file named "<VID>_<PID>.json". Each file holds
//  everything for one physical controller model: hardware id, names, the macOS-provided buttons,
//  the user-identified (learned) buttons, and the rebinds. See controller-mapping.md.
//
//  A controller has an active config only if it is "linked": a registry (UserDefaults) maps the
//  hardware id to the file's path. By default a config is written to and linked from the app's
//  Controllers directory, but the user can import a config from anywhere (which links that path),
//  and removing a config just drops the link, the JSON file stays on disk.
//

import Foundation
import IOKit.hid

// A user-identified extra button (raw-HID bit GameController does not expose).
struct LearnedButton: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var reportID: Int
    var byteIndex: Int
    var bitmask: UInt8

    /// Stable key for "this exact bit", used to skip bits already learned.
    var bitKey: String { "\(reportID):\(byteIndex):\(bitmask)" }
}

// The full per-controller config (the JSON file contents).
struct ControllerConfig: Codable, Equatable {
    var hardwareID: String          // "VVVV:PPPP"
    var vendorID: Int
    var productID: Int
    var controllerName: String      // HID product name (as macOS reports it)
    var displayName: String         // user-editable label
    var macosButtons: [String]      // snapshot of GameController-provided button names
    var learnedButtons: [LearnedButton]
    var bindings: [ControllerBinding]

    static func new(vendorID: Int, productID: Int, name: String, macosButtons: [String]) -> ControllerConfig {
        ControllerConfig(
            hardwareID: ControllerConfigStore.deviceKey(vendorID: vendorID, productID: productID),
            vendorID: vendorID, productID: productID,
            controllerName: name, displayName: name,
            macosButtons: macosButtons, learnedButtons: [], bindings: []
        )
    }
}

enum ControllerConfigStore {
    private static let linksKey = "controllerConfigLinks"   // [deviceKey: filePath]

    static func deviceKey(vendorID: Int, productID: Int) -> String {
        String(format: "%04X:%04X", vendorID, productID)
    }
    static func fileName(vendorID: Int, productID: Int) -> String {
        String(format: "%04X_%04X.json", vendorID, productID)
    }

    /// Default location for new config files: ~/Library/Application Support/ChloroFrame/Controllers.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ChloroFrame/Controllers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Links (registry of active configs -> file paths)

    private static func links() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: linksKey) as? [String: String] ?? [:]
    }
    static func linkedURL(deviceKey: String) -> URL? {
        links()[deviceKey].map { URL(fileURLWithPath: $0) }
    }
    static func setLink(deviceKey: String, url: URL?) {
        var l = links()
        if let url { l[deviceKey] = url.path } else { l.removeValue(forKey: deviceKey) }
        if l.isEmpty { UserDefaults.standard.removeObject(forKey: linksKey) }
        else { UserDefaults.standard.set(l, forKey: linksKey) }
    }

    // MARK: - Load / save / import / remove

    static func load(deviceKey: String) -> ControllerConfig? {
        guard let url = linkedURL(deviceKey: deviceKey),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(ControllerConfig.self, from: data) else { return nil }
        return cfg
    }

    /// Write the config to its linked path (or the default path if not yet linked) and ensure the
    /// link exists. Returns the file URL.
    @discardableResult
    static func save(_ config: ControllerConfig) -> URL? {
        let key = config.hardwareID
        let url = linkedURL(deviceKey: key)
            ?? defaultDirectory().appendingPathComponent(fileName(vendorID: config.vendorID, productID: config.productID))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return nil }
        do { try data.write(to: url, options: .atomic); setLink(deviceKey: key, url: url); return url }
        catch { return nil }
    }

    /// Link and load an existing config file chosen by the user (Import).
    static func importConfig(from url: URL) -> ControllerConfig? {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(ControllerConfig.self, from: data) else { return nil }
        setLink(deviceKey: cfg.hardwareID, url: url)
        return cfg
    }

    /// Drop the link so the controller has no active config. The JSON file is left on disk.
    static func removeConfig(deviceKey: String) {
        setLink(deviceKey: deviceKey, url: nil)
    }

    // MARK: - Runtime helper

    /// The hardware key of the first connected controller-shaped HID device. Opens the manager
    /// (best effort) so CopyDevices reliably enumerates. Used by the translator at stream start.
    static func primaryDeviceKey() -> String? {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))   // best effort; CopyDevices is unreliable otherwise
        defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devices.first else { return nil }
        let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard vid != 0 || pid != 0 else { return nil }
        return deviceKey(vendorID: vid, productID: pid)
    }

    /// Config for the connected controller at stream start: try the enumerated device key, then
    /// fall back to the only linked config if there is exactly one (covers a single controller
    /// even when HID enumeration is flaky).
    static func loadForPrimaryController() -> (key: String?, config: ControllerConfig?) {
        if let key = primaryDeviceKey(), let cfg = load(deviceKey: key) { return (key, cfg) }
        let all = links()
        if all.count == 1, let path = all.values.first,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let cfg = try? JSONDecoder().decode(ControllerConfig.self, from: data) {
            return (all.keys.first, cfg)
        }
        return (primaryDeviceKey(), nil)
    }
}

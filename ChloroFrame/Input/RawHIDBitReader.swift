//
//  RawHIDBitReader.swift
//  ChloroFrame
//
//  Minimal runtime raw-HID reader for the translator (Phase B). Keeps the latest input report
//  bytes per (device, reportID) so learned (paddle) buttons can be polled by their (reportID,
//  byteIndex, bitmask) while streaming. Reports are scoped to the device's hardware key so a
//  second plugged-in device with the same report ID cannot overwrite the active controller's bits.
//  Device matching/removal callbacks handle controllers connected after the stream starts.
//

import Foundation
import IOKit.hid

// Generous fixed buffer: covers controllers whose input reports exceed the common 64 bytes
// (some pack extra buttons past byte 64). The system fills up to this; we read the actual length.
private let kBitReaderBufCapacity = 256

@MainActor
final class RawHIDBitReader {
    private var manager: IOHIDManager?
    private var buffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]
    private var latest: [String: [Int: [UInt8]]] = [:]   // deviceKey -> reportID -> bytes

    func start() {
        guard manager == nil else { return }
        latest.removeAll()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        // Matching/removal fire for already-present devices at open and for hot-plugged ones after.
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<RawHIDBitReader>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.registerReports(for: device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<RawHIDBitReader>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.dropDevice(device) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        for (_, buf) in buffers { buf.deinitialize(count: kBitReaderBufCapacity); buf.deallocate() }
        buffers.removeAll()
        latest.removeAll()
    }

    private func registerReports(for device: IOHIDDevice) {
        let oid = ObjectIdentifier(device)
        guard buffers[oid] == nil else { return }   // already registered
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kBitReaderBufCapacity)
        buf.initialize(repeating: 0, count: kBitReaderBufCapacity)
        buffers[oid] = buf
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, kBitReaderBufCapacity, { ctx, _, sender, _, reportID, report, length in
            guard let ctx, let sender else { return }
            let me = Unmanaged<RawHIDBitReader>.fromOpaque(ctx).takeUnretainedValue()
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let key = ControllerConfigStore.deviceKey(vendorID: vid, productID: pid)
            let count = max(0, min(Int(length), kBitReaderBufCapacity))
            let bytes = Array(UnsafeBufferPointer(start: report, count: count))
            MainActor.assumeIsolated { me.latest[key, default: [:]][Int(reportID)] = bytes }
        }, context)
    }

    private func dropDevice(_ device: IOHIDDevice) {
        let oid = ObjectIdentifier(device)
        if let buf = buffers.removeValue(forKey: oid) {
            buf.deinitialize(count: kBitReaderBufCapacity); buf.deallocate()
        }
    }

    /// Current state of a learned button's bit on a specific device.
    func isSet(deviceKey: String?, reportID: Int, byteIndex: Int, bitmask: UInt8) -> Bool {
        guard let deviceKey, let bytes = latest[deviceKey]?[reportID], byteIndex < bytes.count else { return false }
        return (bytes[byteIndex] & bitmask) != 0
    }
}

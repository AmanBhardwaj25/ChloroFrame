//
//  RawHIDBitReader.swift
//  ChloroFrame
//
//  Minimal runtime raw-HID reader for the translator (Phase B). Keeps the latest input report
//  bytes per reportID so learned (paddle) buttons can be polled by their (reportID, byteIndex,
//  bitmask) while streaming. This is the read side that makes learned-button bindings drive the
//  host; the diagnostic HIDProbe stays UI-only.
//

import Foundation
import IOKit.hid

// Generous fixed buffer: covers controllers whose input reports exceed the common 64 bytes
// (some pack extra buttons past byte 64). The system fills up to this; we read the actual length.
private let kBitReaderBufCapacity = 256

@MainActor
final class RawHIDBitReader {
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var latest: [Int: [UInt8]] = [:]   // reportID -> latest bytes

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
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        guard result == kIOReturnSuccess else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        for device in devices {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kBitReaderBufCapacity)
            buf.initialize(repeating: 0, count: kBitReaderBufCapacity)
            buffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(device, buf, kBitReaderBufCapacity, { ctx, _, _, _, reportID, report, length in
                guard let ctx else { return }
                let me = Unmanaged<RawHIDBitReader>.fromOpaque(ctx).takeUnretainedValue()
                let count = max(0, min(Int(length), kBitReaderBufCapacity))
                let bytes = Array(UnsafeBufferPointer(start: report, count: count))
                MainActor.assumeIsolated { me.latest[Int(reportID)] = bytes }
            }, context)
        }
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        for buf in buffers { buf.deinitialize(count: kBitReaderBufCapacity); buf.deallocate() }
        buffers.removeAll()
        latest.removeAll()
    }

    /// Current state of a learned button's bit.
    func isSet(reportID: Int, byteIndex: Int, bitmask: UInt8) -> Bool {
        guard let bytes = latest[reportID], byteIndex < bytes.count else { return false }
        return (bytes[byteIndex] & bitmask) != 0
    }
}

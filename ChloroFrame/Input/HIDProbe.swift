//
//  HIDProbe.swift
//  ChloroFrame
//
//  Raw HID diagnostic, one level below GameController.framework. GameController only surfaces
//  elements that belong to a recognised profile (Switch Pro, DS4, ...), so anything outside
//  that profile (extra back paddles on a third-party pad) is dropped before we ever see it.
//
//  IOHIDManager sits below that abstraction and delivers every HID value the device reports,
//  including buttons GameController ignores. This probe matches gamepad/joystick devices and
//  logs the distinct button usages it sees, so we can press a paddle and check whether it emits
//  a usage of its own (recoverable) or just mirrors a face button / emits nothing (not
//  recoverable). Diagnostic only: it does not feed input anywhere.
//

import Foundation
import IOKit.hid
import Combine

// Fixed scratch buffer the system fills with each input report. File-scope so the @convention(c)
// report callback (which cannot capture context) can reference it.
private let kReportBufferCapacity = 64

@MainActor
final class HIDProbe: ObservableObject {

    // One distinct HID usage (a button-like input), with its latest value.
    struct Usage: Identifiable {
        let id: String      // "page:usage"
        let page: Int
        let usage: Int
        var value: Int
        var lastChange: Date
        var pressed: Bool { value != 0 }
    }

    // The latest raw input report for one (device, reportID), with the byte indices that changed
    // on the most recent update. This is the paddle hunt: a paddle whose bits are packed into a
    // vendor report shows up as a byte flipping here even when GameController and the element scan
    // see nothing.
    struct ReportSnapshot: Identifiable {
        let id: String      // "device#reportID"
        let device: String
        let reportID: Int
        var bytes: [UInt8]
        var changed: Set<Int>   // normally-stable bytes that flipped recently (a real button)
        var noisy: Set<Int>     // bytes that change constantly (counter, motion, analog axes)
    }

    // A matched raw-HID device, with the USB IDs used to scope learned buttons.
    struct DeviceID: Identifiable {
        let id: String   // deviceKey "VID:PID"
        let name: String
        let vendorID: Int
        let productID: Int
    }

    // A captured extra button from the learn flow: one rising bit with no GameController event.
    struct LearnCandidate {
        let deviceName: String
        let vendorID: Int
        let productID: Int
        let reportID: Int
        let byteIndex: Int
        let bitmask: UInt8
        var deviceKey: String { ControllerConfigStore.deviceKey(vendorID: vendorID, productID: productID) }
    }

    @Published private(set) var running = false
    @Published var logging = false
    @Published private(set) var openError: String?
    @Published private(set) var deviceNames: [String] = []
    @Published private(set) var devices: [DeviceID] = []
    @Published private(set) var usages: [Usage] = []           // sorted, distinct button usages seen
    @Published private(set) var reports: [ReportSnapshot] = [] // latest raw report per device/reportID

    // Learn flow (see controller-mapping.md §3).
    @Published private(set) var learning = false
    @Published var learnCandidate: LearnCandidate?
    /// Provided by the view: the timestamp of the last GameController activity, so we can reject
    /// raw bit flips that coincide with a macOS-known button (a real extra button fires none).
    var lastGCActivity: () -> Date? = { nil }
    private var learnSkipBitKeys: Set<String> = []
    private var pendingCandidate: LearnCandidate?
    private var pendingAt: Date?

    private var manager: IOHIDManager?
    private var seen: [String: Usage] = [:]
    private var reportState: [String: ReportSnapshot] = [:]
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var reportUpdates: [String: Int] = [:]          // total reports seen per key
    private var reportChangeCounts: [String: [Int]] = [:]   // per-byte change tally, to spot noise
    private var reportLit: [String: [Int: Date]] = [:]      // per-byte last "real button" change time
    private var reportValueSets: [String: [Set<UInt8>]] = [:] // distinct values per byte, to spot analog

    // A byte that takes more than this many distinct values is analog (gyro, accel, sticks,
    // triggers, timestamp), not a button. Buttons only ever show a couple of values.
    private static let analogDistinctThreshold = 6

    func start() {
        guard manager == nil else { return }
        seen.removeAll(); usages = []; openError = nil
        reportState.removeAll(); reports = []
        reportUpdates.removeAll(); reportChangeCounts.removeAll(); reportLit.removeAll(); reportValueSets.removeAll()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match controller-shaped devices by their top-level usage. We still receive every
        // element from a matched device, including vendor-defined button pages.
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<HIDProbe>.fromOpaque(ctx).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let v = IOHIDValueGetIntegerValue(value)
            DispatchQueue.main.async { me.record(page: page, usage: usage, value: v) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        if result == kIOReturnSuccess {
            running = true
            refreshDeviceNames(mgr)
            registerReportCallbacks(mgr, context: context)
        } else {
            running = false
            openError = String(format: "IOHIDManagerOpen failed (0x%08X). Input Monitoring may be required.", result)
        }
    }

    // Register a raw input-report callback per matched device. Each needs its own pre-allocated
    // buffer that the system fills; we keep the buffers alive until stop().
    private func registerReportCallbacks(_ mgr: IOHIDManager, context: UnsafeMutableRawPointer) {
        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        for device in devices {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kReportBufferCapacity)
            buf.initialize(repeating: 0, count: kReportBufferCapacity)
            reportBuffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(device, buf, kReportBufferCapacity, { ctx, _, sender, _, reportID, report, length in
                guard let ctx else { return }
                let me = Unmanaged<HIDProbe>.fromOpaque(ctx).takeUnretainedValue()
                var name = "Controller"
                var vid = 0, pid = 0
                if let sender {
                    let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                    if let n = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String { name = n }
                    vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
                    pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
                }
                let count = max(0, min(Int(length), kReportBufferCapacity))
                let bytes = Array(UnsafeBufferPointer(start: report, count: count))
                DispatchQueue.main.async {
                    me.recordReport(device: name, vendorID: vid, productID: pid, reportID: Int(reportID), bytes: bytes)
                }
            }, context)
        }
    }

    // Highlight only meaningful button presses. Controllers like the DS4 stream continuously with
    // a counter byte and motion/touch data, so most bytes flip every report; those are tallied as
    // "noisy" and ignored. A byte that is usually stable but just flipped is a real button, and we
    // keep it lit briefly so a quick tap is visible despite the high report rate.
    private func recordReport(device: String, vendorID: Int, productID: Int, reportID: Int, bytes: [UInt8]) {
        let key = "\(device)#\(reportID)"
        let updates = (reportUpdates[key] ?? 0) + 1
        reportUpdates[key] = updates

        var counts = reportChangeCounts[key] ?? []
        if counts.count < bytes.count { counts += Array(repeating: 0, count: bytes.count - counts.count) }

        var valueSets = reportValueSets[key] ?? []
        if valueSets.count < bytes.count { valueSets += Array(repeating: Set<UInt8>(), count: bytes.count - valueSets.count) }

        var flipped = Set<Int>()
        var flips: [(Int, UInt8, UInt8)] = []   // (index, old, new) for logging
        if let prev = reportState[key] {
            for i in 0 ..< min(prev.bytes.count, bytes.count) where prev.bytes[i] != bytes[i] {
                flipped.insert(i)
                counts[i] += 1
                flips.append((i, prev.bytes[i], bytes[i]))
            }
        }
        for i in 0 ..< bytes.count { valueSets[i].insert(bytes[i]) }
        reportChangeCounts[key] = counts
        reportValueSets[key] = valueSets

        // Noise = analog. A byte is noise if it changes in more than 20% of reports (counter,
        // motion that never settles) OR takes many distinct values (gyro/accel/sticks/triggers
        // that settle but sweep a wide range, e.g. an IMU jolted by a button press). Buttons stay
        // binary, so they are never filtered.
        var noisy = Set<Int>()
        for i in 0 ..< bytes.count {
            let analogByValueCount = valueSets[i].count > Self.analogDistinctThreshold
            let analogByRate = updates > 30 && Double(counts[i]) / Double(updates) > 0.2
            if analogByValueCount || analogByRate { noisy.insert(i) }
        }

        // Latch stable-byte flips for ~0.6s so a tap stays visible, then prune. Drop any byte that
        // has since been reclassified as analog so it stops showing as a button.
        let now = Date()
        var lit = reportLit[key] ?? [:]
        for i in flipped.subtracting(noisy) { lit[i] = now }
        lit = lit.filter { now.timeIntervalSince($0.value) < 0.6 && !noisy.contains($0.key) }
        reportLit[key] = lit

        reportState[key] = ReportSnapshot(id: key, device: device, reportID: reportID,
                                          bytes: bytes, changed: Set(lit.keys), noisy: noisy)
        reports = reportState.values.sorted { ($0.device, $0.reportID) < ($1.device, $1.reportID) }

        // Log candidate-button flips: bytes that are NOT analog. This is the signal to analyze
        // (does a paddle press flip a stable byte, and to a consistent value?). Analog flips are
        // logged too but tagged, so the noise is visible without dominating.
        if logging, !flips.isEmpty {
            let parts = flips.map { i, old, new in
                let tag = noisy.contains(i) ? " analog" : ""
                return String(format: "byte[%d] %02X->%02X%@", i, old, new, tag)
            }
            ProbeLog.shared.log("RAW \(device) rpt\(reportID): " + parts.joined(separator: "  "))
        }

        if learning {
            detectLearnCandidate(device: device, vendorID: vendorID, productID: productID,
                                 reportID: reportID, bytes: bytes, flips: flips, noisy: noisy)
        }
    }

    // A learn candidate is exactly one rising bit in a non-analog byte. That single-bit rule
    // rejects IMU jolts (many bits) and analog sweeps; the no-GameController-activity check (done
    // on confirm) rejects face buttons/dpad/triggers, which always fire a GameController event.
    private func detectLearnCandidate(device: String, vendorID: Int, productID: Int, reportID: Int,
                                      bytes: [UInt8], flips: [(Int, UInt8, UInt8)], noisy: Set<Int>) {
        var totalBits = 0, hitIndex = -1
        var hitMask: UInt8 = 0
        for (i, old, new) in flips where !noisy.contains(i) {
            let x = old ^ new
            totalBits += x.nonzeroBitCount
            if x.nonzeroBitCount == 1 { hitIndex = i; hitMask = x }
        }
        guard totalBits == 1, hitIndex >= 0, (bytes[hitIndex] & hitMask) != 0 else { return }  // single rising bit
        let bitKey = "\(reportID):\(hitIndex):\(hitMask)"
        guard !learnSkipBitKeys.contains(bitKey) else { return }       // already learned
        guard !gcActiveNear(Date()) else { return }                   // coincides with a known button

        // Provisional: confirm no GameController event fires shortly after (handles the race where
        // a known button's GC event lands just after its raw report). A real extra button never
        // produces one.
        let candidate = LearnCandidate(deviceName: device, vendorID: vendorID, productID: productID,
                                       reportID: reportID, byteIndex: hitIndex, bitmask: hitMask)
        pendingCandidate = candidate
        let at = Date(); pendingAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.learning, self.pendingAt == at else { return }
            if !self.gcActiveNear(at) {
                self.learnCandidate = self.pendingCandidate
                self.learning = false
            }
            self.pendingCandidate = nil; self.pendingAt = nil
        }
    }

    private func gcActiveNear(_ t: Date, window: TimeInterval = 0.15) -> Bool {
        guard let g = lastGCActivity() else { return false }
        return abs(g.timeIntervalSince(t)) < window
    }

    /// Begin listening for an unknown extra button. `skip` is the set of already-learned bit keys
    /// (`reportID:byteIndex:bitmask`) to ignore.
    func startLearning(skip: Set<String>) {
        guard running else { return }
        learnSkipBitKeys = skip
        learnCandidate = nil
        pendingCandidate = nil; pendingAt = nil
        learning = true
    }

    func stopLearning() { learning = false; pendingCandidate = nil; pendingAt = nil }
    func clearCandidate() { learnCandidate = nil }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        running = false
        if logging { ProbeLog.shared.log("==== PROBE LOG STOP (scan stopped) ===="); logging = false }
        learning = false; pendingCandidate = nil; pendingAt = nil
        deviceNames = []; devices = []
        // Free the report buffers only after the manager is closed, so the system is no longer
        // writing into them.
        for buf in reportBuffers { buf.deinitialize(count: kReportBufferCapacity); buf.deallocate() }
        reportBuffers.removeAll()
        reportUpdates.removeAll(); reportChangeCounts.removeAll(); reportLit.removeAll(); reportValueSets.removeAll()
    }

    // Only track button-like inputs: the standard Button page (0x09) and vendor-defined pages
    // (0xFF00+), which is where an extra paddle would live if it has its own usage. Axes and the
    // hat switch (Generic Desktop, page 0x01) are skipped so continuous stick motion does not
    // drown out the button presses we are looking for.
    private func record(page: Int, usage: Int, value: Int) {
        guard page == kHIDPage_Button || page >= 0xFF00 else { return }
        let key = "\(page):\(usage)"
        seen[key] = Usage(id: key, page: page, usage: usage, value: value, lastChange: Date())
        usages = seen.values.sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
        if logging { ProbeLog.shared.log("ELEM \(Self.pageName(page)) usage=\(usage) value=\(value)") }
    }

    func setLogging(_ on: Bool) {
        logging = on
        ProbeLog.shared.log(on ? "==== PROBE LOG START device=[\(deviceNames.joined(separator: ", "))] ===="
                               : "==== PROBE LOG STOP ====")
    }

    private func refreshDeviceNames(_ mgr: IOHIDManager) {
        guard let hidDevices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        devices = hidDevices.map { dev in
            let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "Controller"
            let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            return DeviceID(id: ControllerConfigStore.deviceKey(vendorID: vid, productID: pid),
                            name: name, vendorID: vid, productID: pid)
        }.sorted { $0.name < $1.name }
        deviceNames = devices.map(\.name)
    }

    static func pageName(_ page: Int) -> String {
        switch page {
        case kHIDPage_Button:       return "Button"
        case kHIDPage_GenericDesktop: return "Desktop"
        default:                    return page >= 0xFF00 ? "Vendor" : "Page \(page)"
        }
    }
}

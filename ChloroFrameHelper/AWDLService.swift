//
//  AWDLService.swift
//  ChloroFrameHelper
//
//  XPC service object + direct ioctl + route-socket re-suppression monitor.
//  Runs as root (launchd daemon), so SIOCSIFFLAGS succeeds without sudo.
//

import Foundation
import Darwin

private let kSIOCGIFFLAGS: UInt = 0xC0206911   // _IOWR('i', 17, ifreq)
private let kSIOCSIFFLAGS: UInt = 0x80206910   // _IOW ('i', 16, ifreq)
private let kIfname              = "awdl0"

final class AWDLService: NSObject, ChloroFrameHelperProtocol {

    // Tracks whether WE brought awdl0 down so restoreIfNeeded() only acts when necessary.
    // Protected by lock — accessed from XPC queue and route-monitor thread.
    private let stateLock   = NSLock()
    private var _suppressed = false
    private var suppressed: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _suppressed }
        set { stateLock.lock(); _suppressed = newValue; stateLock.unlock() }
    }

    // Tracks whether WE suspended locationd, so restore only resumes what we paused.
    private var _locSuppressed = false
    private var locSuppressed: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _locSuppressed }
        set { stateLock.lock(); _locSuppressed = newValue; stateLock.unlock() }
    }

    override init() {
        super.init()
        startRouteMonitor()
        // Defensive: if a previous helper instance died while locationd was
        // suspended, un-stick it now. SIGCONT on a running process is a no-op.
        _ = setLocationdSuspended(false)
    }

    // MARK: - ChloroFrameHelperProtocol

    func setAWDL(enabled: Bool, reply: @escaping (Bool) -> Void) {
        let ok = ioctl_setInterface(up: enabled)
        if ok { suppressed = !enabled }
        reply(ok)
    }

    func getAWDLEnabled(reply: @escaping (Bool) -> Void) {
        reply(ioctl_isUp())
    }

    func setLocationScanSuppressed(enabled: Bool, reply: @escaping (Bool) -> Void) {
        // enabled == true  → suspend locationd (SIGSTOP), stopping its Wi-Fi scans.
        // enabled == false → resume locationd (SIGCONT).
        let ok = setLocationdSuspended(enabled)
        if ok { locSuppressed = enabled }
        reply(ok)
    }

    func ping(reply: @escaping () -> Void) { reply() }

    // MARK: - Guaranteed restore

    /// Called from the XPC connection's invalidationHandler and from SIGTERM.
    /// Safe to call multiple times — the flags prevent redundant syscalls.
    func restoreIfNeeded() {
        if suppressed {
            NSLog("[ChloroHelper] restoring awdl0")
            _ = ioctl_setInterface(up: true)
            suppressed = false
        }
        if locSuppressed {
            NSLog("[ChloroHelper] resuming locationd")
            _ = setLocationdSuspended(false)
            locSuppressed = false
        }
    }

    // MARK: - ioctl

    private func ioctl_setInterface(up: Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            NSLog("[ChloroHelper] socket() failed errno=\(errno)")
            return false
        }
        defer { close(fd) }

        var ifr = ifreq()
        ifr_setName(&ifr, kIfname)

        guard withUnsafeMutablePointer(to: &ifr, { Darwin.ioctl(fd, kSIOCGIFFLAGS, $0) }) == 0 else {
            NSLog("[ChloroHelper] SIOCGIFFLAGS failed errno=\(errno)")
            return false
        }

        let isUp = (ifr.ifr_ifru.ifru_flags & Int16(IFF_UP)) != 0
        if isUp == up {
            NSLog("[ChloroHelper] awdl0 already \(up ? "UP" : "DOWN")")
            return true
        }

        if up { ifr.ifr_ifru.ifru_flags |=  Int16(IFF_UP) }
        else  { ifr.ifr_ifru.ifru_flags &= ~Int16(IFF_UP) }

        let setErr = withUnsafeMutablePointer(to: &ifr) { Darwin.ioctl(fd, kSIOCSIFFLAGS, $0) }
        if setErr == 0 {
            NSLog("[ChloroHelper] awdl0 → \(up ? "UP" : "DOWN") ✓")
        } else {
            NSLog("[ChloroHelper] SIOCSIFFLAGS failed errno=\(errno) (\(String(cString: strerror(errno))))")
        }
        return setErr == 0
    }

    private func ioctl_isUp() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var ifr = ifreq()
        ifr_setName(&ifr, kIfname)
        guard withUnsafeMutablePointer(to: &ifr, { Darwin.ioctl(fd, kSIOCGIFFLAGS, $0) }) == 0 else { return false }
        return (ifr.ifr_ifru.ifru_flags & Int16(IFF_UP)) != 0
    }

    private func ifr_setName(_ ifr: inout ifreq, _ name: String) {
        withUnsafeMutablePointer(to: &ifr.ifr_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) {
                _ = strncpy($0, name, Int(IFNAMSIZ) - 1)
            }
        }
    }

    // MARK: - locationd suspend / resume

    /// Sends SIGSTOP (suspend) or SIGCONT (resume) to locationd. Runs as root so
    /// kill() succeeds; SIP protects locationd from debugging, not from signals.
    private func setLocationdSuspended(_ suspend: Bool) -> Bool {
        guard let pid = locationdPID() else {
            NSLog("[ChloroHelper] locationd not found")
            return false
        }
        let sig = suspend ? SIGSTOP : SIGCONT
        if kill(pid, sig) == 0 {
            NSLog("[ChloroHelper] locationd \(suspend ? "SIGSTOP" : "SIGCONT") pid \(pid) ✓")
            return true
        }
        NSLog("[ChloroHelper] kill(\(pid), \(suspend ? "STOP" : "CONT")) failed errno=\(errno)")
        return false
    }

    private func locationdPID() -> pid_t? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "locationd"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch {
            NSLog("[ChloroHelper] pgrep launch failed: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let first = String(data: data, encoding: .utf8)?
                .split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return pid
    }

    // MARK: - Route-socket re-suppression monitor

    /// Watches RTM_IFINFO on AF_ROUTE. If awdl0 is raised by another process
    /// while we're suppressing, immediately bring it back down.
    private func startRouteMonitor() {
        let t = Thread { [weak self] in self?.routeMonitorLoop() }
        t.name = "chloro-helper.route-monitor"
        t.qualityOfService = .utility
        t.start()
    }

    private func routeMonitorLoop() {
        let rtfd = socket(AF_ROUTE, SOCK_RAW, 0)
        guard rtfd >= 0 else {
            NSLog("[ChloroHelper] AF_ROUTE socket failed")
            return
        }
        defer { close(rtfd) }
        _ = fcntl(rtfd, F_SETFL, O_NONBLOCK)

        let targetIdx = if_nametoindex(kIfname)
        let bufSize = max(MemoryLayout<rt_msghdr>.size, MemoryLayout<if_msghdr>.size) + 64
        var buf = [UInt8](repeating: 0, count: bufSize)

        while true {
            var pfd = pollfd(fd: rtfd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, -1)
            if n < 0 { if errno == EINTR { continue } else { break } }

            while read(rtfd, &buf, buf.count) > 0 {
                buf.withUnsafeBytes { raw in
                    guard raw.count >= MemoryLayout<rt_msghdr>.size else { return }
                    let rtm = raw.load(as: rt_msghdr.self)
                    guard rtm.rtm_type == UInt8(RTM_IFINFO),
                          raw.count >= MemoryLayout<if_msghdr>.size else { return }
                    let ifm = raw.load(as: if_msghdr.self)
                    guard ifm.ifm_index == UInt16(targetIdx) else { return }
                    if suppressed && (ifm.ifm_flags & Int32(IFF_UP)) != 0 {
                        NSLog("[ChloroHelper] awdl0 raised externally — re-suppressing")
                        _ = ioctl_setInterface(up: false)
                    }
                }
            }
        }
    }
}

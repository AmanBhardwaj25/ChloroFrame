//
//  AWDLSuppressor.swift
//  ChloroFrame
//
//  XPC client for the privileged ChloroFrameHelper daemon.
//  The helper runs as root (SMAppService daemon) and does ioctl(SIOCSIFFLAGS) directly.
//  Guaranteed restore: helper's connection invalidationHandler fires on app crash.
//

import Foundation
import ServiceManagement
import Darwin

// MARK: - AWDLSuppressor

final class AWDLSuppressor {
    static let shared = AWDLSuppressor()

    static let helperID = "fullstacksandbox.com.ChloroFrame.Helper"

    private var connection: NSXPCConnection?
    private var active = false

    private init() {}

    // MARK: - Helper status

    /// The SMAppService daemon backed by Contents/Library/LaunchDaemons/<plist>.
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: "\(AWDLSuppressor.helperID).plist")
    }

    /// True only when the daemon is registered AND approved by the user.
    var isHelperInstalled: Bool {
        daemonService.status == .enabled
    }

    // MARK: - Installation (SMAppService)

    /// Registers the privileged daemon. macOS 13+ replacement for SMJobBless: the
    /// daemon runs in-place from the app bundle (no copy to /Library/...), and the
    /// user approves it once under System Settings > General > Login Items & Extensions.
    /// Throws `.requiresApproval` (and opens that pane) when approval is pending.
    /// `force: true` re-registers even when status reads `.enabled`. Needed because a
    /// Debug rebuild re-signs the binary and silently staleness the registered job (status
    /// stays `.enabled` but launchd won't launch it), so the daemon never answers XPC.
    @MainActor
    func installHelper(force: Bool = false) throws {
        let svc = daemonService

        if !force, svc.status == .enabled {
            print("[AWDLSuppressor] helper already enabled ✓")
            return
        }

        // Re-registering refreshes an existing registration. We deliberately do NOT call
        // unregister() first: if the registration was created by a different binary signature
        // (e.g. a prior build), unregister() is denied with EPERM and wedges the item. When
        // that happens the user must clear the background item in System Settings manually.
        try svc.register()

        switch svc.status {
        case .enabled:
            print("[AWDLSuppressor] helper registered ✓")
        case .requiresApproval:
            print("[AWDLSuppressor] helper needs approval — opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
            throw AWDLHelperError.requiresApproval
        default:
            throw AWDLHelperError.registrationFailed(svc.status)
        }
    }

    // MARK: - Suppress / Restore

    func suppress() {
        guard !active else { return }
        let wantAWDL = UserDefaults.standard.bool(forKey: "suppressAWDLDuringStream")
        let wantLoc  = UserDefaults.standard.bool(forKey: "suppressWiFiScansDuringStream")
        guard wantAWDL || wantLoc else {
            print("[AWDLSuppressor] both suppressions disabled — skipping")
            return
        }
        guard isHelperInstalled else {
            print("[AWDLSuppressor] helper not installed — skipping (open Settings to set up)")
            return
        }

        let conn = makeConnection()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
            print("[AWDLSuppressor] suppress: XPC error — \(err.localizedDescription)")
        }) as? ChloroFrameHelperProtocol else { return }

        active = true

        if wantAWDL {
            proxy.setAWDL(enabled: false) { ok in
                print("[AWDLSuppressor] suppress → \(ok ? "awdl0 down ✓" : "ioctl failed")")
            }
        }
        if wantLoc {
            proxy.setLocationScanSuppressed(enabled: true) { ok in
                print("[AWDLSuppressor] suppress → \(ok ? "locationd suspended ✓" : "kill failed")")
            }
        }
    }

    /// Sends the restore commands and blocks until the helper confirms (or times out).
    /// Resumes both awdl0 and locationd unconditionally; the helper no-ops whichever
    /// it didn't actually suppress. Safe to call from any thread.
    func restore() {
        guard active, let conn = connection else { return }

        let group = DispatchGroup()
        if let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
            print("[AWDLSuppressor] restore: XPC error — \(err.localizedDescription)")
        }) as? ChloroFrameHelperProtocol {
            group.enter()
            proxy.setAWDL(enabled: true) { ok in
                print("[AWDLSuppressor] restore → \(ok ? "awdl0 up ✓" : "ioctl failed")")
                group.leave()
            }
            group.enter()
            proxy.setLocationScanSuppressed(enabled: false) { ok in
                print("[AWDLSuppressor] restore → \(ok ? "locationd resumed ✓" : "kill failed")")
                group.leave()
            }
        }

        if group.wait(timeout: .now() + 3.0) == .timedOut {
            print("[AWDLSuppressor] restore: timed out waiting for helper reply")
        }

        conn.invalidate()
        connection = nil
        active = false
    }

    // MARK: - Connection

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(
            machServiceName: AWDLSuppressor.helperID,
            options: .privileged          // .privileged = connecting to a LaunchDaemon
        )
        conn.remoteObjectInterface = NSXPCInterface(with: ChloroFrameHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            print("[AWDLSuppressor] XPC connection invalidated")
            DispatchQueue.main.async {
                self?.connection = nil
                self?.active = false
            }
        }
        conn.resume()
        connection = conn
        return conn
    }
}

// MARK: - AWDLStatusMonitor

/// Polls awdl0 IFF_UP once per second. Read-only ioctl — no privileges needed.
@Observable
final class AWDLStatusMonitor {
    private(set) var isActive: Bool = AWDLSuppressor.isAWDLActive()
    private var timer: Timer?

    func start() {
        isActive = AWDLSuppressor.isAWDLActive()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.isActive = AWDLSuppressor.isAWDLActive()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - One-shot status read (unprivileged)

private let kSIOCGIFFLAGS: UInt = 0xC0206911   // _IOWR('i', 17, ifreq)

extension AWDLSuppressor {
    /// Returns true if awdl0 currently has IFF_UP set.
    /// Uses SIOCGIFFLAGS which is read-only and does not require root.
    static func isAWDLActive() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var ifr = ifreq()
        withUnsafeMutablePointer(to: &ifr.ifr_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) {
                _ = strncpy($0, "awdl0", Int(IFNAMSIZ) - 1)
            }
        }
        guard withUnsafeMutablePointer(to: &ifr, { Darwin.ioctl(fd, kSIOCGIFFLAGS, $0) }) == 0 else {
            return false
        }
        return (ifr.ifr_ifru.ifru_flags & Int16(IFF_UP)) != 0
    }
}

// MARK: - Errors

enum AWDLHelperError: LocalizedError {
    case requiresApproval
    case registrationFailed(SMAppService.Status)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "Approve ChloroFrame in System Settings > General > Login Items & Extensions, then try again."
        case .registrationFailed(let status):
            return "Helper registration failed (status \(status.rawValue))."
        }
    }
}

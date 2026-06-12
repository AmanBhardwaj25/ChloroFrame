//
//  AWDLSuppressor.swift
//  ChloroFrame
//
//  XPC client for the privileged ChloroFrameHelper daemon.
//  The helper runs as root (SMJobBless) and does ioctl(SIOCSIFFLAGS) directly.
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

    /// True if the helper binary is installed in /Library/PrivilegedHelperTools/.
    var isHelperInstalled: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/PrivilegedHelperTools/\(AWDLSuppressor.helperID)"
        )
    }

    // MARK: - Installation (SMJobBless)

    /// Prompts for admin credentials and installs (or updates) the privileged helper.
    /// Call from the main thread; the auth dialog is modal.
    @MainActor
    func installHelper() throws {
        var authItem  = AuthorizationItem(
            name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0
        )
        var authRights = AuthorizationRights(count: 1, items: &authItem)
        var authRef: AuthorizationRef?

        let createErr = AuthorizationCreate(
            &authRights, nil,
            [.interactionAllowed, .preAuthorize, .extendRights],
            &authRef
        )
        guard createErr == errAuthorizationSuccess, let ref = authRef else {
            throw AWDLHelperError.authorizationFailed(createErr)
        }
        defer { AuthorizationFree(ref, [.destroyRights]) }

        var cfErr: Unmanaged<CFError>?
        guard SMJobBless(
            kSMDomainSystemLaunchd,
            AWDLSuppressor.helperID as CFString,
            ref, &cfErr
        ) else {
            throw cfErr?.takeRetainedValue() ?? AWDLHelperError.blessFailed
        }
        print("[AWDLSuppressor] helper installed ✓")
    }

    // MARK: - Suppress / Restore

    func suppress() {
        guard !active else { return }
        guard UserDefaults.standard.bool(forKey: "suppressAWDLDuringStream") else {
            print("[AWDLSuppressor] setting disabled — skipping")
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

        proxy.setAWDL(enabled: false) { [weak self] ok in
            print("[AWDLSuppressor] suppress → \(ok ? "awdl0 down ✓" : "ioctl failed")")
            DispatchQueue.main.async { self?.active = ok }
        }
    }

    /// Sends the restore command and blocks until the helper confirms (or times out).
    /// Safe to call from any thread; uses a semaphore so the caller knows restore completed.
    func restore() {
        guard active, let conn = connection else { return }

        let sem = DispatchSemaphore(value: 0)
        let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
            print("[AWDLSuppressor] restore: XPC error — \(err.localizedDescription)")
            sem.signal()
        }) as? ChloroFrameHelperProtocol

        proxy?.setAWDL(enabled: true) { ok in
            print("[AWDLSuppressor] restore → \(ok ? "awdl0 up ✓" : "ioctl failed")")
            sem.signal()
        }

        let result = sem.wait(timeout: .now() + 3.0)
        if result == .timedOut {
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
    case authorizationFailed(OSStatus)
    case blessFailed

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let s): return "Authorization failed (OSStatus \(s))"
        case .blessFailed:                return "SMJobBless failed — check signing and Info.plist"
        }
    }
}

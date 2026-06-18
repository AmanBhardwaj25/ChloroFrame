//
//  ChloroFrameHelperProtocol.swift
//  ChloroFrame + ChloroFrameHelper (add to both targets)
//

import Foundation

/// XPC interface shared between the main app and the privileged helper.
/// The helper runs as root via SMJobBless; the main app connects to its Mach service.
@objc(ChloroFrameHelperProtocol)
protocol ChloroFrameHelperProtocol {
    /// Bring awdl0 up (enabled=true) or down (enabled=false).
    /// reply(true) on success, reply(false) on ioctl failure.
    func setAWDL(enabled: Bool, reply: @escaping (Bool) -> Void)

    /// Read current awdl0 IFF_UP state without changing it.
    func getAWDLEnabled(reply: @escaping (Bool) -> Void)

    /// Suspend (enabled=true) or resume (enabled=false) locationd via SIGSTOP/SIGCONT.
    /// While suspended, locationd cannot issue its periodic Wi-Fi positioning scan —
    /// the ~0.5s/60s off-channel radio stall that spikes streaming latency. Reversible.
    /// reply(true) on success, reply(false) if locationd wasn't found or kill() failed.
    func setLocationScanSuppressed(enabled: Bool, reply: @escaping (Bool) -> Void)

    /// No-op round-trip used to verify the connection is live.
    func ping(reply: @escaping () -> Void)
}

//
//  HelperXPCDelegate.swift
//  ChloroFrameHelper
//

import Foundation

final class HelperXPCDelegate: NSObject, NSXPCListenerDelegate {

    private let service: AWDLService

    init(service: AWDLService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {

        conn.exportedInterface = NSXPCInterface(with: ChloroFrameHelperProtocol.self)
        conn.exportedObject    = service

        // Restore awdl0 if the main app crashes or is force-quit.
        // If stop() was called cleanly, service.suppressed is already false — this is a no-op.
        conn.invalidationHandler = { [weak self] in
            NSLog("[ChloroHelper] XPC connection invalidated — restoring awdl0 if needed")
            self?.service.restoreIfNeeded()
        }
        conn.interruptionHandler = { [weak self] in
            // Interruption means the connection dropped but may reconnect.
            // Treat like invalidation to be safe.
            NSLog("[ChloroHelper] XPC connection interrupted — restoring awdl0 if needed")
            self?.service.restoreIfNeeded()
        }

        conn.resume()
        return true
    }
}

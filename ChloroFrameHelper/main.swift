//
//  main.swift
//  ChloroFrameHelper
//
//  Created by Aman Bhardwaj on 6/9/26.
//

import Foundation

/// The privileged helper's main entry point.
/// Runs as a launchd daemon, listens on the Mach service, and handles XPC connections from the main app.

let kHelperMachService = "fullstacksandbox.com.ChloroFrame.Helper"

let service  = AWDLService()
let delegate = HelperXPCDelegate(service: service)
let listener = NSXPCListener(machServiceName: kHelperMachService)

listener.delegate = delegate

// Restore awdl0 on SIGTERM (launchctl stop or system shutdown).
signal(SIGTERM) { _ in
    NSLog("[ChloroHelper] SIGTERM received — restoring awdl0 before exit")
    service.restoreIfNeeded()
    exit(0)
}

NSLog("[ChloroHelper] listening on Mach service: \(kHelperMachService)")
listener.resume()

// Keep the helper running.
RunLoop.current.run()


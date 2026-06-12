//
//  StreamState.swift
//  ChloroFrame
//

import AppKit

// Errors that can terminate a running stream.
enum StreamError: LocalizedError {
    case controlDisconnected
    case rendererUnavailable
    var errorDescription: String? {
        switch self {
        case .controlDisconnected: return "Control stream disconnected"
        case .rendererUnavailable: return "Metal renderer is unavailable"
        }
    }
}

// Shared, main-thread-isolated state for an active streaming session.
// Created once in ContentView and passed via .environment(); populated by
// HostConnectionView when a stream starts successfully.
@Observable @MainActor
final class StreamState {
    var transport:     StreamTransport?
    var renderer:      MetalVideoRenderer?
    var inputHandler:  InputHandler?
    var stats:         StreamStatsCollector?
    var appName:       String = ""
    var codecInfo:     String = ""
    var disconnectError: Error?

    private var cancelClosure: (() async -> Void)?

    var isActive: Bool { transport != nil }

    func activate(
        transport:    StreamTransport,
        renderer:     MetalVideoRenderer,
        inputHandler: InputHandler,
        appName:      String,
        codecInfo:    String,
        onCancel:     @escaping () async -> Void
    ) {
        self.transport     = transport
        self.renderer      = renderer
        self.inputHandler  = inputHandler
        self.stats         = transport.stats
        self.appName       = appName
        self.codecInfo     = codecInfo
        self.cancelClosure = onCancel
        self.disconnectError = nil
    }

    func stop() {
        let cancel = cancelClosure
        deactivate(reason: "user stop")
        if let cancel { Task { await cancel() } }
    }

    func didDisconnect(error: Error) {
        deactivate(reason: "control disconnected")
        disconnectError = error
    }

    private func deactivate(reason: String) {
        guard transport != nil || renderer != nil || inputHandler != nil || stats != nil else { return }
        print("[ChloroFrame][stream] deactivate reason=\(reason)")
        inputHandler?.releaseAll()  // must be before transport.stop() so release packets can be sent
        transport?.stop(reason: reason)
        transport     = nil
        renderer      = nil
        inputHandler  = nil
        stats         = nil
        cancelClosure = nil
        appName       = ""
        codecInfo     = ""
    }
}

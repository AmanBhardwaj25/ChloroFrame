//
//  ChloroFrameApp.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI
import AppKit

@main
struct ChloroFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("ChloroFrame", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            StreamCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.register(defaults: ["suppressAWDLDuringStream": true])
        NetworkMonitor.shared.start()
        // Defer sizing to the next run loop tick so SwiftUI's initial layout
        // pass completes first — calling setContentSize mid-layout causes the
        // -layoutSubtreeIfNeeded recursion warning.
        DispatchQueue.main.async {
            guard let screen = NSScreen.main,
                  let window = NSApplication.shared.windows.first else { return }
            let visible = screen.visibleFrame
            let width  = max(720, (visible.width  * 0.55).rounded())
            let height = max(480, (visible.height * 0.55).rounded())
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

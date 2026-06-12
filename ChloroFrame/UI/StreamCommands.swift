//
//  StreamCommands.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI

struct StreamCommands: Commands {
    var body: some Commands {
        CommandMenu("Stream") {
            Button("Add Host...") {
                NotificationCenter.default.post(name: .showAddHost, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Disconnect") {
                NotificationCenter.default.post(name: .disconnect, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Full Screen") {
                NotificationCenter.default.post(name: .toggleFullScreen, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}

extension Notification.Name {
    static let showAddHost = Notification.Name("showAddHost")
    static let disconnect = Notification.Name("disconnect")
    static let toggleFullScreen = Notification.Name("toggleFullScreen")
}

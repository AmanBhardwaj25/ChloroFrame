//
//  TVChloroFrameApp.swift
//  ChloroFrameTV
//
//  Created by Aman Bhardwaj on 6/21/26.
//
//  tvOS app entry point. Deliberately minimal for the Phase 1 compile skeleton:
//  no AppKit, no menu commands, no Settings scene, no privileged helper. SwiftUI
//  app lifecycle backed by the tvOS focus engine. Streaming is wired up in later
//  phases (see design/tvos-port-plan.md).
//

import SwiftUI

@main
struct TVChloroFrameApp: App {
    init() {
        // tvOS-only defaults. None of the macOS AWDL / Wi-Fi-scan suppression keys
        // apply here; those features are intentionally dropped for tvOS.
        UserDefaults.standard.register(defaults: [:])
    }

    var body: some Scene {
        WindowGroup {
            TVContentView()
        }
    }
}

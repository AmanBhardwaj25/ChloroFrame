//
//  TVTheme.swift
//  ChloroFrameTV
//
//  Brand colors for the tvOS UI, inlined so the views do not depend on a shared
//  asset catalog. These approximate the macOS CFBackground / CFSurface / CFGold
//  palette. Swap to a tvOS asset catalog during the UI polish phase.
//

import SwiftUI

enum TVTheme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let surface    = Color(red: 0.10, green: 0.12, blue: 0.15)
    static let gold       = Color(red: 0.83, green: 0.69, blue: 0.36)
}

//
//  TVContentView.swift
//  ChloroFrameTV
//
//  Created by Aman Bhardwaj on 6/21/26.
//
//  Phase 1 placeholder host-list screen. Its only job for now is to prove the
//  target launches, the tvOS focus engine works with the Siri Remote, and the
//  visual language reads at 10 feet. Real host management, pairing, app list,
//  and streaming arrive in Phase 3 onward.
//

import SwiftUI

struct TVContentView: View {
    // Brand colors inlined for the skeleton so this view does not depend on a
    // shared asset catalog yet. These approximate the macOS CFBackground / CFGold
    // palette; swap to a tvOS asset catalog during the UI pass.
    private static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    private static let gold = Color(red: 0.83, green: 0.69, blue: 0.36)

    var body: some View {
        ZStack {
            TVContentView.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 40) {
                header

                Text("No hosts yet")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Button {
                    // Phase 3: present the add-host flow.
                } label: {
                    Label("Add Host", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 12)
                }

                Spacer()
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(TVContentView.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text("ChloroFrame")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                Text("Apple TV  ·  alpha")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    TVContentView()
}

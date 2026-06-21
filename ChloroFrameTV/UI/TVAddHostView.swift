//
//  TVAddHostView.swift
//  ChloroFrameTV
//
//  Manual add-host entry (Phase 3). tvOS native text fields for a display name and
//  IP address. mDNS/Bonjour discovery is a non-goal for the MVP, so hosts are added
//  by address. Default port matches the macOS client (47989).
//

import SwiftUI

struct TVAddHostView: View {
    /// (name, address, port)
    var onAdd: (String, String, UInt16) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""

    private var canAdd: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 32) {
                Text("Add Host")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 20) {
                    TextField("Name (optional)", text: $name)
                    TextField("IP address", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.URL)
                }
                .frame(maxWidth: 700)

                HStack(spacing: 24) {
                    Button("Cancel", role: .cancel) { dismiss() }

                    Button {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        let trimmedAddr = address.trimmingCharacters(in: .whitespaces)
                        onAdd(trimmedName.isEmpty ? trimmedAddr : trimmedName, trimmedAddr, 47989)
                        dismiss()
                    } label: {
                        Label("Add", systemImage: "plus")
                            .padding(.horizontal, 12)
                    }
                    .disabled(!canAdd)
                }

                Spacer()
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview {
    TVAddHostView { _, _, _ in }
}

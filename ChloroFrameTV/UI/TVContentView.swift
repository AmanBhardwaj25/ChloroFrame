//
//  TVContentView.swift
//  ChloroFrameTV
//
//  Host list (Phase 3). Lists saved hosts as focusable cards, lets the user add a
//  host by IP, and pushes the connection/pairing/negotiation flow when one is
//  selected. Host data and persistence are shared with macOS via HostManager.
//

import SwiftUI

struct TVContentView: View {
    @State private var hosts = HostManager()
    @State private var showAddHost = false
    @State private var path: [Host] = []
    @FocusState private var focusedHost: Host.ID?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVTheme.background.ignoresSafeArea()
                content
            }
            .navigationDestination(for: Host.self) { host in
                TVHostConnectionView(host: host)
            }
        }
        .sheet(isPresented: $showAddHost) {
            TVAddHostView { name, address, port in
                hosts.add(name: name, address: address, port: port)
                // Move the remote's focus onto the just-added card so the user
                // does not have to hunt for it after the sheet dismisses.
                let newID = hosts.hosts.last?.id
                DispatchQueue.main.async { focusedHost = newID }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 48) {
            header

            if hosts.hosts.isEmpty {
                emptyState
            } else {
                hostGrid
            }

            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(TVTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("ChloroFrame")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
                Text("Apple TV  ·  alpha")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddHost = true
            } label: {
                Label("Add Host", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No hosts yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add a host by its IP address to get started.")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 80)
    }

    private var hostGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: 32)],
                spacing: 32
            ) {
                ForEach(hosts.hosts) { host in
                    Button {
                        path.append(host)
                    } label: {
                        TVHostCard(host: host)
                    }
                    .buttonStyle(.card)
                    .focused($focusedHost, equals: host.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            hosts.remove(host)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .defaultFocus($focusedHost, hosts.hosts.first?.id)
    }
}

private struct TVHostCard: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(TVTheme.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name.isEmpty ? host.address : host.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(host.address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(TVTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview {
    TVContentView()
}

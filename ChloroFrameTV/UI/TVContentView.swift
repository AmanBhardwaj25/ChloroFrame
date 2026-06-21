//
//  TVContentView.swift
//  ChloroFrameTV
//
//  Host list (Phase 3). Lists saved hosts as focusable cards plus an "Add Host" tile,
//  and pushes the connection/pairing/negotiation flow when a host is selected. Host data
//  and persistence are shared with macOS via HostManager.
//
//  Focus notes:
//   - Every focusable control (host cards + the Add tile) lives in the same grid. tvOS traps
//     focus inside a ScrollView, so a control outside it (e.g. a header button) is unreachable.
//   - Focus is tracked with a FocusTarget enum so both the hosts and the Add tile have an
//     identity. When a focused host is removed, tvOS drops focus into limbo, so we explicitly
//     move it to a remaining host or the Add tile.
//

import SwiftUI

struct TVContentView: View {
    @State private var hosts = HostManager()
    @State private var showAddHost = false
    @State private var path: [Host] = []
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable {
        case host(Host.ID)
        case addHost
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVTheme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 40) {
                    header

                    ScrollView {
                        grid
                            .padding(.bottom, 8)
                    }

                    if !hosts.hosts.isEmpty {
                        Text("Hold the Select button on a host to remove it.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationDestination(for: Host.self) { host in
                TVHostConnectionView(host: host)
            }
        }
        .sheet(isPresented: $showAddHost) {
            TVAddHostView { name, address, port in
                hosts.add(name: name, address: address, port: port)
                // Move focus onto the just-added card so the user doesn't have to hunt for it.
                if let newID = hosts.hosts.last?.id {
                    DispatchQueue.main.async { focus = .host(newID) }
                }
            }
        }
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
        }
    }

    private var grid: some View {
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
                .focused($focus, equals: .host(host.id))
                .contextMenu {
                    Button(role: .destructive) {
                        remove(host)
                    } label: {
                        Label("Remove Host", systemImage: "trash")
                    }
                }
            }

            // Add-host tile: a focus peer of the host cards, so it's always reachable.
            Button {
                showAddHost = true
            } label: {
                TVAddHostTile()
            }
            .buttonStyle(.card)
            .focused($focus, equals: .addHost)
        }
        .defaultFocus($focus, hosts.hosts.first.map { .host($0.id) } ?? .addHost)
    }

    private func remove(_ host: Host) {
        hosts.remove(host)
        // tvOS drops focus when the focused card disappears; move it somewhere valid.
        let next: FocusTarget = hosts.hosts.first.map { .host($0.id) } ?? .addHost
        DispatchQueue.main.async { focus = next }
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

private struct TVAddHostTile: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(TVTheme.gold)
            Text("Add Host")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(TVTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview {
    TVContentView()
}

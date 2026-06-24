//
//  ContentView.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import SwiftUI

// MARK: - Model

struct Host: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var port: UInt16 = 47989
}

// MARK: - Host Manager

@Observable
class HostManager {
    var hosts: [Host] = []
    var isScanning = false

    private let storageKey = "chloroframe.hosts"

    init() { load() }

    func add(name: String, address: String, port: UInt16) {
        hosts.append(Host(name: name, address: address, port: port))
        persist()
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    func scanLocalNetwork() {
        guard !isScanning else {
            print("[HostManager] scanLocalNetwork: already scanning — ignored")
            return
        }
        print("[HostManager] scanLocalNetwork: starting scan (mDNS/Bonjour not yet implemented)")
        isScanning = true
        // TODO: mDNS/Bonjour discovery — replace the timeout stub below with NWBrowser
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            print("[HostManager] scanLocalNetwork: stub timeout elapsed, scan complete (0 hosts found)")
            self?.isScanning = false
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([Host].self, from: data) else { return }
        hosts = saved
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var hostManager    = HostManager()
    @State private var streamState    = StreamState()
    @State private var showAddressEntry = false
    @State private var connectingHost: Host?
    @State private var showStats      = false
    @State private var showControls   = false
    @State private var showControlsHelp = false
    @State private var controlsHideWork: DispatchWorkItem?
    @State private var awdlMonitor    = AWDLStatusMonitor()
    @AppStorage("absoluteMouseMode") private var absoluteMouseMode = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if streamState.isActive {
                streamingView
            } else {
                hostListView
                    .frame(minWidth: 720, minHeight: 480)
            }
        }
        .background(Color("CFBackground"))
        .sheet(isPresented: $showAddressEntry) {
            AddHostSheet { name, address, port in
                hostManager.add(name: name, address: address, port: port)
            }
        }
        .sheet(item: $connectingHost) { host in
            HostConnectionView(host: host)
                .environment(streamState)
        }
        .sheet(isPresented: $showControlsHelp) {
            StreamControlsHelpView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddHost)) { _ in
            showAddressEntry = true
        }
        .alert("Stream Ended", isPresented: Binding(
            get: { streamState.disconnectError != nil },
            set: { if !$0 { streamState.disconnectError = nil } }
        )) {
            Button("OK") { streamState.disconnectError = nil }
        } message: {
            Text(streamState.disconnectError?.localizedDescription ?? "")
        }
        .onChange(of: streamState.isActive) { _, active in
            // Small delay lets SwiftUI finish its re-render before we request
            // the window to enter/exit fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = NSApp.windows.first(where: { !$0.isSheet && !$0.isMiniaturized }) else { return }
                let isFS = window.styleMask.contains(.fullScreen)
                if active && !isFS  { window.toggleFullScreen(nil) }
                if !active && isFS  { window.toggleFullScreen(nil) }
            }
        }
        // ⌘⌃F (Stream ▸ Toggle Full Screen) posts this; without a handler the menu item was a
        // no-op. Toggling out of fullscreen mid-stream gives a windowed session (the renderer
        // tracks the view's drawable size, so it adapts).
        .onReceive(NotificationCenter.default.publisher(for: .toggleFullScreen)) { _ in
            guard let window = NSApp.windows.first(where: { !$0.isSheet && !$0.isMiniaturized }) else { return }
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Streaming view (replaces host list when a session is active)
    // No chrome — just the raw video surface + optional stats HUD.
    // Ctrl+⌥+⌘+Q to disconnect · Ctrl+⌥+⌘+S to toggle stats

    private var streamingView: some View {
        ZStack(alignment: .topLeading) {
            if let r = streamState.renderer {
                MetalVideoView(
                    renderer: r,
                    streamFps: streamState.presentFps,
                    inputHandler: streamState.inputHandler,
                    onDisconnect: { streamState.stop() },
                    onToggleStats: { showStats.toggle() },
                    onShowControls: { revealControlsOverlay() },
                    absoluteMouseMode: absoluteMouseMode,
                    onToggleMouseMode: { absoluteMouseMode.toggle() }
                )
            } else {
                Color.black
            }

            if showStats, let collector = streamState.stats {
                StreamStatsHUD(collector: collector, awdlActive: awdlMonitor.isActive)
                    .padding(16)
                    .allowsHitTesting(false)
            }

            if showControls {
                controlsOverlay
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .onAppear  { awdlMonitor.start() }
        .onDisappear { awdlMonitor.stop(); controlsHideWork?.cancel() }
    }

    // Translucent card listing the stream shortcuts. Shown after holding ⌃⌥⌘ for 2 s,
    // auto-hides after 6 s.
    private var controlsOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream controls")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            StreamControlsList(onLight: false)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
        )
        .frame(maxWidth: 460)
    }

    private func revealControlsOverlay() {
        controlsHideWork?.cancel()
        showControls = true
        let work = DispatchWorkItem { showControls = false }
        controlsHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    // MARK: - Host list view

    private var hostListView: some View {
        VStack(spacing: 0) {
            headerBar
            discoverySection
            Divider()
            hostsSection
            controlsHint
        }
    }

    // Subtle pointer so users learn the in-stream gesture even before their first session.
    private var controlsHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("While streaming, hold \(StreamControlsInfo.trio) to see stream controls.")
            Button("Learn more") { showControlsHelp = true }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(alignment: .center) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .cornerRadius(8)
            Text("ChloroFrame")
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            Button { showControlsHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stream controls")
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    // MARK: Discovery

    private var discoverySection: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                Text("Search for new Hosts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                DiscoveryButton(
                    icon: "network",
                    title: "Search Local Network",
                    isLoading: hostManager.isScanning
                ) {
                    print("[ContentView] Search Local Network tapped (isScanning=\(hostManager.isScanning))")
                    hostManager.scanLocalNetwork()
                }
                DiscoveryButton(
                    icon: "square.and.pencil",
                    title: "Enter Address"
                ) {
                    showAddressEntry = true
                }
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
    }

    // MARK: Hosts

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hosts")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 16)

            if hostManager.hosts.isEmpty {
                Text("No saved hosts")
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(hostManager.hosts) { host in
                            HostCard(host: host) {
                                connectingHost = host
                            } onRemove: {
                                hostManager.remove(host)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 160)
    }
}

// MARK: - Discovery Button

struct DiscoveryButton: View {
    let icon: String
    let title: String
    var isLoading = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                    }
                }
                .frame(height: 30)

                Text(title)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .frame(width: 168, height: 86)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color("CFSurface") : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Host Card

struct HostCard: View {
    let host: Host
    let onConnect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onConnect) {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.primary)
                Text(host.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .frame(width: 96, height: 104)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color("CFSurface") : Color("CFSurface").opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .contextMenu {
            Text("\(host.address):\(host.port)")
            Divider()
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove Host", systemImage: "trash")
            }
        }
        .help(host.address)
    }
}

// MARK: - Add Host Sheet

struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var port = 47989

    let onAdd: (String, String, UInt16) -> Void

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Host")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Name", text: $name)
                TextField("IP Address or Hostname", text: $address)
                TextField("Port", value: $port, format: .number)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    onAdd(
                        name.trimmingCharacters(in: .whitespaces),
                        address.trimmingCharacters(in: .whitespaces),
                        UInt16(clamping: port)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

#Preview {
    ContentView()
}

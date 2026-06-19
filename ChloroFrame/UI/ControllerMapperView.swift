//
//  ControllerMapperView.swift
//  ChloroFrame
//
//  Controller setup page. Everything for the connected controller lives in one per-controller
//  config file (<VID>_<PID>.json, see ControllerConfigStore): display name, macOS-provided
//  buttons, user-identified extra buttons, and the rebinds. The page lets you identify extra
//  buttons, rebind known/learned buttons to gamepad combos or a host keyboard chord, and
//  import/remove the config file.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ControllerMapperView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var input = ControllerInput()
    @StateObject private var hid = HIDProbe()

    @State private var config: ControllerConfig?     // current controller's config (in memory)
    @State private var configURL: URL?               // linked file path, nil if not saved/linked
    @State private var pending: Pending?
    @State private var pendingLabel = ""

    private struct Pending {
        var sources: [BindingSource] = []
        var kind: Kind = .gamepad
        var gamepad: Set<GamepadButton> = []
        var keys: [String] = []
        enum Kind: String, CaseIterable { case gamepad = "Gamepad", keyboard = "Keyboard" }
    }

    // Derived from config.
    private var learned: [LearnedButton] { config?.learnedButtons ?? [] }
    private var bindings: [ControllerBinding] { config?.bindings ?? [] }
    // Live macOS buttons, or the config's saved snapshot if GameController hasn't repopulated yet.
    private var knownButtonNames: [String] { input.knownButtons.isEmpty ? (config?.macosButtons ?? []) : input.knownButtons }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    connectedSection
                    configSection
                    liveSection
                    extraButtonsSection
                    bindingsSection
                    rawHIDSection
                }
                .padding(20)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity,
               minHeight: 420, idealHeight: 680, maxHeight: .infinity)
        .onAppear { hid.lastGCActivity = { input.lastEvent?.at }; hid.start(); loadConfig() }
        .onChange(of: hid.devices.map(\.id)) { _, _ in loadConfig() }
        .onChange(of: hid.learnCandidate?.bitmask) { _, _ in pendingLabel = "" }
        .onDisappear { input.stopListening(); hid.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Controller").font(.headline)
            Text("Identify extra buttons, then rebind known or labeled buttons to gamepad combos or a host keyboard chord. Settings save to a per-controller config file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Connected controllers

    private var connectedSection: some View {
        section("Connected") {
            if input.controllers.isEmpty {
                Label("No controller detected. Pair one over Bluetooth or plug it in.",
                      systemImage: "gamecontroller")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if input.controllers.count > 1 {
                    Text("Select which controller to view and remap.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(input.controllers) { c in
                    let selected = input.selectedID == c.id
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "gamecontroller.fill")
                                    .foregroundStyle(selected ? .green : .secondary)
                                Text(c.displayName).fontWeight(.semibold)
                                Text("(\(c.profileKind))").foregroundStyle(.secondary)
                            }
                            Text("\(c.category) · \(c.elementCount) elements · " + capabilities(c))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { input.select(c.id) }
                }
            }
        }
    }

    private func capabilities(_ c: ControllerInput.ControllerInfo) -> String {
        var parts: [String] = []
        parts.append(c.hasMotion ? "motion" : "no motion")
        if c.hasHaptics { parts.append("rumble") }
        if c.hasLight { parts.append("lightbar") }
        if c.hasBattery { parts.append("battery") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Configuration (per-controller file)

    private var configSection: some View {
        section("Configuration") {
            if let c = config {
                HStack {
                    Text("Name").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    TextField("Display name", text: displayName).textFieldStyle(.roundedBorder)
                        .onSubmit { persist() }
                }
                Text("\(c.controllerName) · \(c.hardwareID)")
                    .font(.caption2).foregroundStyle(.secondary)

                if let url = configURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(url.path).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .font(.caption2).buttonStyle(.link)
                    }
                } else {
                    Text("Not saved yet. Identifying a button or adding a binding creates the file.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Import config…") { importConfig() }
                    if configURL != nil {
                        Button("Remove config") { removeConfig() }.tint(.red)
                    }
                    Spacer()
                }
                .font(.caption)
            } else {
                Text("Connect a controller to configure it, or import an existing config file.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Import config…") { importConfig() }.font(.caption)
            }
        }
    }

    private var displayName: Binding<String> {
        Binding(get: { config?.displayName ?? "" }, set: { config?.displayName = $0 })
    }

    // MARK: - Live readout

    private var liveSection: some View {
        section("Live input") {
            if let e = input.lastEvent {
                HStack(spacing: 8) {
                    if let sym = e.symbolName { Image(systemName: sym).font(.title2) }
                    Text(e.elementName).fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%.2f", e.value))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(e.pressed ? .green : .secondary)
                }
            } else {
                Text("Press anything on the controller…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !input.liveValues.isEmpty {
                Divider()
                ForEach(input.liveValues.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                    HStack {
                        Text(name).font(.caption)
                        Spacer()
                        ProgressView(value: Double(min(max(value, 0), 1))).frame(width: 120)
                    }
                }
            }
        }
    }

    // MARK: - Extra buttons (learn flow)

    private var extraButtonsSection: some View {
        section("Extra buttons") {
            Text("Buttons macOS does not recognize (back paddles, etc.). Capture one, label it, then it becomes bindable below.")
                .font(.caption2).foregroundStyle(.secondary)

            ForEach(learned) { lb in
                HStack(spacing: 6) {
                    Image(systemName: "button.programmable").foregroundStyle(.secondary)
                    Text(lb.label).fontWeight(.medium)
                    Text(String(format: "rpt %d · byte %d · 0x%02X", lb.reportID, lb.byteIndex, lb.bitmask))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { deleteLearned(lb) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }

            if let cand = hid.learnCandidate {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    Text("Captured: \(cand.deviceName)")
                    Text(String(format: "rpt %d · byte %d · 0x%02X", cand.reportID, cand.byteIndex, cand.bitmask))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    TextField("Label (e.g. Back Paddle 1)", text: $pendingLabel)
                        .textFieldStyle(.roundedBorder).onSubmit { saveLearned() }
                    Button("Save") { saveLearned() }.buttonStyle(.borderedProminent).disabled(!canSaveLearned)
                    Button("Discard") { hid.clearCandidate(); pendingLabel = "" }
                }
                .font(.caption)
                if !pendingLabel.isEmpty, isDuplicateLabel {
                    Text("That label is already used.").font(.caption2).foregroundStyle(.red)
                }
            } else {
                HStack {
                    Button(hid.learning ? "Press an unmapped button…" : "Map extra buttons") {
                        if hid.learning { hid.stopLearning() } else { startLearning() }
                    }
                    Spacer()
                }
                .font(.caption)
                if hid.learning {
                    Text("Press the extra button once. Do not touch the sticks, triggers, or face buttons.")
                        .font(.caption2).foregroundStyle(.green)
                }
                if let err = hid.openError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Bindings

    private var bindingsSection: some View {
        section("Remaps") {
            if bindings.isEmpty {
                Text("No remaps yet. Click “Add binding”, pick one or more known buttons as the trigger, then choose what they do.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(bindings) { b in
                    HStack(spacing: 6) {
                        Text(b.sourceSummary).font(.callout).fontWeight(.medium)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        Text(b.target.summary).font(.callout)
                            .foregroundStyle(Color(red: 0.70, green: 0.52, blue: 0.0))
                        Spacer()
                        Button(role: .destructive) { deleteBinding(b) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            if pending != nil {
                pendingEditor
            } else {
                HStack {
                    Button("Add binding") { pending = Pending() }
                        .disabled(knownButtonNames.isEmpty && learned.isEmpty)
                    if !bindings.isEmpty {
                        Button("Clear all") { config?.bindings = []; persist() }
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var pendingEditor: some View {
        if let p = pending {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Source: tap one button, or several for a combo").font(.caption2).foregroundStyle(.secondary)
                let columns = [GridItem(.adaptive(minimum: 92), spacing: 6)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(knownButtonNames, id: \.self) { name in
                        sourceChip(.gamepad(name: name), label: name, system: nil)
                    }
                    ForEach(learned) { lb in
                        sourceChip(.learned(deviceKey: config?.hardwareID ?? "", bitKey: lb.bitKey, label: lb.label),
                                   label: lb.label, system: "button.programmable")
                    }
                }
                if !p.sources.isEmpty {
                    Text("Trigger: " + p.sources.map(\.displayName).joined(separator: " + "))
                        .font(.caption).foregroundStyle(Color(red: 0.70, green: 0.52, blue: 0.0))
                }

                Divider()
                Text("Target").font(.caption2).foregroundStyle(.secondary)
                Picker("Target", selection: pendingKind) {
                    ForEach(Pending.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)

                if p.kind == .gamepad { gamepadPicker } else { keyboardPicker }

                HStack {
                    Button("Cancel") { cancelPending() }
                    Spacer()
                    Button("Save") { savePending() }
                        .buttonStyle(.borderedProminent).disabled(!canSavePending)
                }
                .font(.caption)
            }
        }
    }

    private func sourceChip(_ source: BindingSource, label: String, system: String?) -> some View {
        let on = pending?.sources.contains(source) ?? false
        return HStack(spacing: 3) {
            if let system { Image(systemName: system).font(.caption2) }
            Text(label).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(on ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.15)))
        .contentShape(Rectangle())
        .onTapGesture { toggleSource(source) }
    }

    private var gamepadPicker: some View {
        let columns = [GridItem(.adaptive(minimum: 62), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(GamepadButton.allCases) { btn in
                let on = pending?.gamepad.contains(btn) ?? false
                Text(btn.label)
                    .font(.caption2).frame(maxWidth: .infinity).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(on ? Color.accentColor.opacity(0.4) : Color.gray.opacity(0.15)))
                    .contentShape(Rectangle())
                    .onTapGesture { toggleGamepad(btn) }
            }
        }
    }

    private var keyboardPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let keys = pending?.keys, !keys.isEmpty {
                    Text(KeyToken.summary(keys)).foregroundStyle(Color(red: 0.70, green: 0.52, blue: 0.0))
                    Button("Clear") { pending?.keys = [] }
                } else {
                    Text("Click keys on the host keyboard below (e.g. Alt + Tab).").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HostKeyboardView(selected: Set(pending?.keys ?? []), onTap: toggleKey)
            }
        }
    }

    // MARK: - Raw HID (advanced)

    private var rawHIDSection: some View {
        section("Raw HID (advanced)") {
            Text("Sees buttons below GameController, including ones it hides. Used by Map extra buttons; also a diagnostic.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button(hid.running ? "Stop" : "Start raw scan") { hid.running ? hid.stop() : hid.start() }
                if hid.running {
                    Button(hid.logging ? "Stop logging" : "Log to session.log") { hid.setLogging(!hid.logging) }
                }
                if hid.running, !hid.deviceNames.isEmpty {
                    Text(hid.deviceNames.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)

            if let err = hid.openError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }

            if hid.running, !hid.reports.isEmpty {
                Text("Raw reports — keep sticks centered, tap a paddle, watch for an orange byte. Dimmed bytes change constantly and are ignored.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(hid.reports) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(r.device) · report \(r.reportID) · \(r.bytes.count) bytes")
                            .font(.caption2).foregroundStyle(.secondary)
                        let columns = [GridItem(.adaptive(minimum: 24), spacing: 3)]
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                            ForEach(Array(r.bytes.enumerated()), id: \.offset) { i, byte in
                                let lit = r.changed.contains(i)
                                let noisy = r.noisy.contains(i)
                                Text(String(format: "%02X", byte))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(noisy ? .secondary : .primary).opacity(noisy ? 0.4 : 1)
                                    .padding(.vertical, 2).frame(maxWidth: .infinity)
                                    .background(RoundedRectangle(cornerRadius: 3)
                                        .fill(lit ? Color.orange.opacity(0.7) : Color.gray.opacity(0.12)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Remaps drive the host when streaming with this controller connected.",
                  systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Config load/save

    private func loadConfig() {
        guard let dev = hid.devices.first else { config = nil; configURL = nil; return }
        if let existing = ControllerConfigStore.load(deviceKey: dev.id) {
            config = existing
            configURL = ControllerConfigStore.linkedURL(deviceKey: dev.id)
        } else if config?.hardwareID != dev.id {
            config = ControllerConfig.new(vendorID: dev.vendorID, productID: dev.productID,
                                          name: dev.name, macosButtons: input.knownButtons)
            configURL = nil
        }
    }

    /// Ensure config exists for the connected device (used before the first save).
    private func ensureConfig() {
        if config == nil, let dev = hid.devices.first {
            config = ControllerConfig.new(vendorID: dev.vendorID, productID: dev.productID,
                                          name: dev.name, macosButtons: input.knownButtons)
        }
    }

    private func persist() {
        guard var c = config else { return }
        if !input.knownButtons.isEmpty { c.macosButtons = input.knownButtons }
        config = c
        configURL = ControllerConfigStore.save(c)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a controller config (.json) to import."
        if panel.runModal() == .OK, let url = panel.url, let cfg = ControllerConfigStore.importConfig(from: url) {
            config = cfg
            configURL = url
        }
    }

    private func removeConfig() {
        guard let dev = hid.devices.first else { return }
        ControllerConfigStore.removeConfig(deviceKey: dev.id)   // unlink; file stays on disk
        config = ControllerConfig.new(vendorID: dev.vendorID, productID: dev.productID,
                                      name: dev.name, macosButtons: input.knownButtons)
        configURL = nil
    }

    // MARK: - Binding actions

    private var pendingKind: Binding<Pending.Kind> {
        Binding(get: { pending?.kind ?? .gamepad }, set: { pending?.kind = $0 })
    }

    private var canSavePending: Bool {
        guard let p = pending, !p.sources.isEmpty else { return false }
        return p.kind == .gamepad ? !p.gamepad.isEmpty : !p.keys.isEmpty
    }

    private func toggleSource(_ s: BindingSource) {
        guard pending != nil else { return }
        if let i = pending!.sources.firstIndex(of: s) { pending!.sources.remove(at: i) } else { pending!.sources.append(s) }
    }
    private func toggleGamepad(_ b: GamepadButton) {
        guard pending != nil else { return }
        if pending!.gamepad.contains(b) { pending!.gamepad.remove(b) } else { pending!.gamepad.insert(b) }
    }
    private func toggleKey(_ token: String) {
        guard pending != nil else { return }
        if let i = pending!.keys.firstIndex(of: token) { pending!.keys.remove(at: i) } else { pending!.keys.append(token) }
    }

    private func savePending() {
        guard let p = pending else { return }
        ensureConfig()
        let target: BindingTarget = p.kind == .gamepad
            ? .gamepad(GamepadButton.allCases.filter { p.gamepad.contains($0) })
            : .keyboard(KeyToken.ordered(p.keys))
        config?.bindings.append(ControllerBinding(sources: p.sources, target: target))
        persist()
        cancelPending()
    }

    private func cancelPending() { pending = nil }

    private func deleteBinding(_ b: ControllerBinding) {
        config?.bindings.removeAll { $0.id == b.id }
        persist()
    }

    // MARK: - Learn flow actions

    private var isDuplicateLabel: Bool {
        let l = pendingLabel.trimmingCharacters(in: .whitespaces).lowercased()
        return learned.contains { $0.label.lowercased() == l }
    }
    private var canSaveLearned: Bool {
        !pendingLabel.trimmingCharacters(in: .whitespaces).isEmpty && !isDuplicateLabel
    }

    private func startLearning() {
        if !hid.running { hid.start() }
        hid.startLearning(skip: Set(learned.map(\.bitKey)))
    }

    private func saveLearned() {
        guard canSaveLearned, let cand = hid.learnCandidate else { return }
        ensureConfig()
        config?.learnedButtons.append(LearnedButton(label: pendingLabel.trimmingCharacters(in: .whitespaces),
                                                    reportID: cand.reportID, byteIndex: cand.byteIndex, bitmask: cand.bitmask))
        persist()
        hid.clearCandidate()
        pendingLabel = ""
    }

    private func deleteLearned(_ lb: LearnedButton) {
        config?.learnedButtons.removeAll { $0.id == lb.id }
        persist()
    }

    // Matches SettingsView's grouped section styling.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }
}

#Preview {
    ControllerMapperView()
}

//
//  PyroWaveReadinessViews.swift
//  ChloroFrame
//
//  Views for the PyroWave experimental gate (design/pyrowave-implementation-plan.md D5b):
//  the warning/info sheet, the "may not work well" sheet and the full readiness report.
//

import SwiftUI
import AppKit

// MARK: - Experimental notice (Settings)

struct PyroWaveNoticeView: View {
    enum Mode {
        /// Shown when PyroWave is selected: the user must accept or cancel.
        case confirm(onEnable: () -> Void, onCancel: () -> Void)
        /// Opened from the info button: read-only.
        case info(onClose: () -> Void)
    }

    let mode: Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PyroWaveExperimentalNotice.experimentalParagraph.markdown)
            Text(PyroWaveExperimentalNotice.vibeshineParagraph.markdown)
            Text(PyroWaveExperimentalNotice.checklistIntro)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PyroWaveExperimentalNotice.checklist, id: \.text) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                        Text(item.text)
                    }
                }
            }
            .padding(.leading, 8)
            Text(PyroWaveExperimentalNotice.fallbackParagraph)

            HStack {
                Spacer()
                switch mode {
                case .confirm(let onEnable, let onCancel):
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Enable PyroWave", action: onEnable)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                case .info(let onClose):
                    Button("Close", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }
}

// MARK: - Warnings before launch

struct PyroWaveWarningsView: View {
    let report: PyroWaveAuditReport
    let onStream: () -> Void
    let onUseHEVC: () -> Void
    let onCancel: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PyroWave may not work well on this setup")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(report.warnings) { w in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.title).font(.subheadline.weight(.semibold))
                            // The band-unknown row carries the exact warning copy as its detail.
                            Text(w.detail ?? w.message ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Details") { showDetails = true }
                Spacer()
                Button("Use HEVC", action: onUseHEVC)
                Button("Stream with PyroWave anyway", action: onStream)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
        .sheet(isPresented: $showDetails) {
            PyroWaveAuditReportView(report: report, onClose: { showDetails = false })
        }
    }
}

// MARK: - Full report

struct PyroWaveAuditReportView: View {
    let report: PyroWaveAuditReport
    var title: String = "PyroWave readiness"
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(report.blocked ? .red : (report.warnings.isEmpty ? .green : .orange))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.results) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol(r)).foregroundStyle(color(r)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(r.id)  \(r.title)").font(.subheadline.weight(.semibold))
                                if let m = r.message {
                                    Text(m).font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                                if let d = r.detail {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.logLines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 480)
    }

    private var summary: String {
        if let line = report.fallbackHeadline { return line }
        if report.warnings.isEmpty { return "This host is ready for PyroWave." }
        let n = report.warnings.count
        return "PyroWave can be used, with \(n) warning\(n == 1 ? "" : "s")."
    }

    private func symbol(_ r: PyroWaveCheckResult) -> String {
        switch r.outcome {
        case .pass: return "checkmark.circle.fill"
        case .fail: return r.severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        case .unknown: return r.failedAsBlocker ? "questionmark.octagon.fill"
                                                : (r.isWarning ? "exclamationmark.triangle.fill" : "questionmark.circle")
        }
    }

    private func color(_ r: PyroWaveCheckResult) -> Color {
        switch r.outcome {
        case .pass: return .green
        case .fail: return r.severity == .blocker ? .red : .orange
        case .unknown: return r.failedAsBlocker ? .red : (r.isWarning ? .orange : .secondary)
        }
    }
}

private extension String {
    /// Inline markdown (the notice copy uses **bold**), falling back to plain text.
    var markdown: AttributedString {
        (try? AttributedString(markdown: self)) ?? AttributedString(self)
    }
}

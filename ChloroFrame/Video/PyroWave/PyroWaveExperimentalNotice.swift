//
//  PyroWaveExperimentalNotice.swift
//  ChloroFrame
//
//  Single source for the PyroWave experimental warning (design/pyrowave-implementation-plan.md
//  D5b Part A). The checklist lives here as data so a test can keep it in step with the audit
//  catalog: every row marked `userFacing` in PyroWaveReadinessAudit.catalog must be promised
//  below, and nothing else may be.
//
//  Bump `version` whenever the text changes materially; the sheet is shown again only then.
//

import Foundation

nonisolated enum PyroWaveExperimentalNotice {

    /// Stored in @AppStorage("pyroWaveNoticeAcknowledgedVersion") when the user accepts.
    static let version = 1
    static let acknowledgedKey = "pyroWaveNoticeAcknowledgedVersion"

    static let title = "PyroWave is experimental"

    // Markdown, rendered with Text(LocalizedStringKey). No em dashes or en dashes.
    static let experimentalParagraph =
        "**PyroWave is experimental.** It is a new codec, and its macOS decoder comes from the "
        + "upstream PyroWave project, which ChloroFrame does not control. Its author describes the "
        + "macOS port as minimally maintained, and upstream issues have already been found and "
        + "patched around. Expect bugs, visual artifacts and dropped frames, some of which "
        + "ChloroFrame cannot fix."

    static let vibeshineParagraph =
        "**PyroWave only works with Vibeshine hosts.** Apollo and Sunshine cannot stream it."

    static let checklistIntro =
        "Before PyroWave is used with a host, ChloroFrame checks that host's setup:"

    struct ChecklistItem: Equatable, Sendable {
        let text: String
        /// Audit check ids this bullet promises.
        let checkIDs: [String]
    }

    static let checklist: [ChecklistItem] = [
        ChecklistItem(text: "the Mac has an Apple silicon GPU that can decode PyroWave in time",
                      checkIDs: ["C1", "C15"]),
        ChecklistItem(text: "the host runs Vibeshine with PyroWave enabled",
                      checkIDs: ["C2"]),
        ChecklistItem(text: "the host and this Mac are on the same local network (no VPN or internet path)",
                      checkIDs: ["C4"]),
        ChecklistItem(text: "the host is connected by Ethernet",
                      checkIDs: ["C5"]),
        ChecklistItem(text: "this Mac is on Ethernet, or on 5 GHz or 6 GHz Wi-Fi",
                      checkIDs: ["C6"]),
        ChecklistItem(text: "both links are fast enough for the selected bitrate",
                      checkIDs: ["C7"]),
    ]

    static let fallbackParagraph =
        "If a required check fails, ChloroFrame streams with HEVC instead and tells you why. "
        + "PyroWave needs hundreds of Mbps: about 220 Mbps for 1080p at 60 fps, and more at "
        + "higher resolutions and frame rates."

    /// Shown in the warnings sheet when the Wi-Fi band could not be verified (user decision
    /// 2026-10-14: a soft warning, never a block).
    static let bandUnknownWarning =
        "ChloroFrame couldn't verify that this Mac is on 5 GHz or 6 GHz Wi-Fi. PyroWave needs a "
        + "fast, clean wireless link; on 2.4 GHz or a congested network, expect dropped frames, "
        + "stutter and visual artifacts."

    /// Every check id the notice promises.
    static var promisedCheckIDs: Set<String> {
        Set(checklist.flatMap(\.checkIDs))
    }

    /// The whole notice as plain text, for tests and accessibility.
    static var fullText: String {
        ([experimentalParagraph, vibeshineParagraph, checklistIntro]
         + checklist.map { "- \($0.text)" }
         + [fallbackParagraph]).joined(separator: "\n")
    }
}

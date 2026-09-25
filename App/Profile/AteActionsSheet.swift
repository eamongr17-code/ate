import AteKit
import SwiftUI

/// **`Actions`** — everything you can do *about* somebody, in one sheet: save what they ate, send
/// it on, report it, or never see them again.
///
/// The same sheet from a profile's "…" and from someone else's entry, because they are the same four
/// answers and the same action must work identically everywhere it appears (AGENTS.md rule 2). Only
/// "Save this place" differs: on an entry it saves that visit's dishes, and a profile has no visit to
/// save, so it is simply absent rather than disabled.
///
/// Report and Block ask first — a native confirmation dialog, which is both the confirm step and the
/// only feedback the design will carry (no toast, no banner, no helper copy).
struct AteActionsSheet: View {
    /// The handle, as the sheet's own title.
    let title: String
    let blockTitle: String
    /// Absent on a profile.
    var onSavePlace: (() -> Void)?
    /// What to hand the system share sheet directly — a link to a profile. An empty array cancels
    /// quietly. Ignored when ``onShareReceipt`` answers with an artefact.
    var onShare: () -> [Any]
    /// An entry's share card, when this sheet is about an entry. It presents the **same** `Share`
    /// screen the entry page's share icon does — one action, one artefact, everywhere it appears
    /// (AGENTS.md rule 2).
    var onShareReceipt: (() -> ShareArtefact?)?
    /// Where `receipt_shared` is sent from. Only used on the receipt path.
    var analytics: AnalyticsRecorder = { _ in }
    var onReport: () -> Void
    var onBlock: () -> Void

    @State private var isConfirmingReport = false
    @State private var isConfirmingBlock = false
    @State private var sharing: SharePayload?
    @State private var sharingReceipt: SharingReceipt?
    /// A browser tapped a write. The sheet goes first and `Welcome` asks once it has gone — a cover
    /// cannot be presented from under a sheet that is still up.
    @State private var askOnceGone: SessionGate.Trigger?
    @Environment(SessionGate.self) private var gate: SessionGate?
    @Environment(\.dismiss) private var dismiss

    /// What is being sent — `Identifiable` so it can present a sheet.
    private struct SharePayload: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private struct SharingReceipt: Identifiable {
        let artefact: ShareArtefact
        var id: UUID { artefact.entryID ?? UUID() }
    }

    var body: some View {
        AteSheet(title: title) {
            VStack(spacing: 0) {
                if let onSavePlace {
                    row(icon: .save, title: "Save this place") {
                        guard mayWrite(.save) else { return }
                        onSavePlace()
                        dismiss()
                    }
                }
                row(icon: .share, title: "Share") {
                    if let artefact = onShareReceipt?() {
                        sharingReceipt = SharingReceipt(artefact: artefact)
                        return
                    }
                    let items = onShare()
                    guard items.isEmpty == false else { return }
                    sharing = SharePayload(items: items)
                }
                row(icon: .flag, title: "Report") {
                    guard mayWrite(.report) else { return }
                    isConfirmingReport = true
                }
                row(icon: .block, title: blockTitle, tint: AteColor.destructive) {
                    guard mayWrite(.block) else { return }
                    isConfirmingBlock = true
                }
            }
        }
        .presentationDetents([.height(AteScreen.sheetHeight(420))])
        .onDisappear {
            guard let trigger = askOnceGone else { return }
            _ = gate?.permitsWrite(trigger)
        }
        .confirmationDialog("Report \(title)?", isPresented: $isConfirmingReport, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                onReport()
                dismiss()
            }
            .accessibilityIdentifier("actions.confirmReport")
        }
        .confirmationDialog(blockTitle + "?", isPresented: $isConfirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                onBlock()
                dismiss()
            }
            .accessibilityIdentifier("actions.confirmBlock")
        }
        .sheet(item: $sharing) { payload in
            ShareSheet(items: payload.items)
        }
        .fullScreenCover(item: $sharingReceipt) { sharing in
            ShareScreen(artefact: sharing.artefact, source: .actions, analytics: analytics)
        }
    }

    /// Save, Report and Block are writes. Somebody browsing signed out is asked to sign in instead —
    /// the same ask a bookmark in the feed makes (AGENTS.md rule 2).
    private func mayWrite(_ trigger: SessionGate.Trigger) -> Bool {
        guard let gate, gate.isBrowsing else { return true }
        askOnceGone = trigger
        dismiss()
        return false
    }

    /// `min-height:60px; gap:14px`, ruled at the top — the sheet's own row.
    private func row(icon: AteIcon, title: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: 14) {
                    icon.view(size: 22)
                    Text(title).ateText(.rowTitle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 60)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? AtePalette.surface.fg)
        .accessibilityIdentifier("actions.\(title)")
    }
}

#if DEBUG
private struct ActionsPreview: View {
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .ateGround()
            .sheet(isPresented: $isPresented) {
                AteActionsSheet(
                    title: "@jessw",
                    blockTitle: "Block @jessw",
                    onSavePlace: {},
                    onShare: { [URL(string: "https://ate.app/@jessw")!] },
                    onReport: {},
                    onBlock: {}
                )
            }
    }
}

#Preview("Actions") { ActionsPreview() }
#endif

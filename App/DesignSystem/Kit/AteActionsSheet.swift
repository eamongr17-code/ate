import AteKit
import SwiftUI

/// **The actions sheet** — Save, Share, Report and Block, the same sheet everywhere it appears (a
/// profile's •••, somebody else's entry). The rows and their asks are ``ActionsSheetRow``'s; this
/// draws them on the one sheet scaffold. Save is a toggle that shows which way it will go and flips in
/// place; Report and Block ask once in a native confirmation dialog; Share hands the system share
/// sheet a link. Somebody browsing signed out who taps a write is asked to sign in instead.
struct AteActionsSheet: View {
    /// The handle, as the sheet's own title.
    let title: String
    let blockTitle: String
    /// Absent where there is nothing to save (a profile).
    var onSave: (() -> Void)?
    var isSaved = false
    var onShare: () -> [Any]
    var onReport: () -> Void
    var onBlock: () -> Void

    @State private var confirming: ActionsSheetRow?
    @State private var sharing: Payload?
    @State private var askOnceGone: SessionGate.Trigger?
    @Environment(SessionGate.self) private var gate: SessionGate?
    @Environment(\.dismiss) private var dismiss

    private struct Payload: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        AteSheetScaffold(title: title, detents: [.medium]) {
            VStack(spacing: 0) {
                ForEach(ActionsSheetRow.rows(canSave: onSave != nil)) { row in
                    button(for: row)
                }
            }
        }
        .onDisappear {
            guard let trigger = askOnceGone else { return }
            _ = gate?.permitsWrite(trigger)
        }
        .confirmationDialog(
            confirming == .block ? blockTitle + "?" : "Report \(title)?",
            isPresented: Binding(get: { confirming != nil }, set: { if $0 == false { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { row in
            Button(row == .block ? "Block" : "Report", role: .destructive) {
                if row == .block { onBlock() } else { onReport() }
                dismiss()
            }
        }
        .sheet(item: $sharing) { ShareSheet(items: $0.items) }
    }

    private func button(for row: ActionsSheetRow) -> some View {
        Button {
            tap(row)
        } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteActionsSheetMetrics.gap) {
                    icon(for: row).view(size: AteActionsSheetMetrics.icon)
                    Text(title(for: row)).ateText(.rowTitle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: AteActionsSheetMetrics.rowHeight)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(row.isDestructive ? AteColor.destructive : AtePalette.surface.fg)
        .accessibilityAddTraits(row == .save && isSaved ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("actions.\(row.rawValue)")
    }

    private func tap(_ row: ActionsSheetRow) {
        if row.isWrite, let gate, gate.isBrowsing, let trigger = trigger(for: row) {
            askOnceGone = trigger
            dismiss()
            return
        }
        switch row {
        case .save: onSave?()
        case .share:
            let items = onShare()
            if items.isEmpty == false { sharing = Payload(items: items) }
        case .report, .block: confirming = row
        }
    }

    private func trigger(for row: ActionsSheetRow) -> SessionGate.Trigger? {
        switch row {
        case .save: .save
        case .report: .report
        case .block: .block
        case .share: nil
        }
    }

    private func icon(for row: ActionsSheetRow) -> AteIcon {
        switch row {
        case .save: isSaved ? .saved : .save
        case .share: .share
        case .report: .flag
        case .block: .block
        }
    }

    private func title(for row: ActionsSheetRow) -> String {
        switch row {
        case .save: isSaved ? "Place saved" : "Save this place"
        case .share: "Share"
        case .report: "Report"
        case .block: blockTitle
        }
    }
}

enum AteActionsSheetMetrics {
    /// `.arow{min-height:60px; gap:14px}`, its icon 22.
    static let rowHeight: CGFloat = 60
    static let gap: CGFloat = 14
    static let icon: CGFloat = 22
}

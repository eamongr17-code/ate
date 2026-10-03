import SwiftUI

/// **The sheet scaffold** — one layout, every sheet. A native sheet (detents, the system grabber) on
/// the control surface; close is a glass disc top left; the primary action, if there is one, a glass
/// disc top right (the ink tick, or Share); the title in Bricolage 800 at 30, left, under the corner
/// row; an optional 50pt search pill in the field colour; the content; and, on a sheet that applies a
/// choice, one ink pill at the foot carrying a live count. A sheet that picks one row closes on the
/// tap and has no pill.
struct AteSheetScaffold<Content: View>: View {
    /// The top-right disc.
    struct Primary {
        var icon: AteIcon
        var label: String
        var isEnabled = true
        var isBusy = false
        var action: () -> Void
    }

    /// The foot's ink pill — "Show 12 entries".
    struct Commit {
        var title: String
        var isEnabled = true
        var action: () -> Void
    }

    let title: String
    var primary: Primary?
    var searchPrompt: String?
    var searchText: Binding<String>?
    var commit: Commit?
    var detents: Set<PresentationDetent> = [.medium, .large]
    /// What close does; dismisses the sheet by default.
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AteGlassDisc(icon: .close, label: "Close", identifier: "sheet.close") {
                    if let onClose { onClose() } else { dismiss() }
                }
                Spacer(minLength: 0)
                if let primary {
                    AteGlassDisc(
                        icon: primary.icon,
                        label: primary.label,
                        role: .primary,
                        isEnabled: primary.isEnabled,
                        isBusy: primary.isBusy,
                        identifier: "sheet.primary",
                        action: primary.action
                    )
                }
            }
            .padding(.horizontal, AteSheetScaffoldMetrics.cornerInset)
            .padding(.top, AteSheetScaffoldMetrics.cornerTop)
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                Text(title)
                    .ateText(.sheetTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let searchText, let searchPrompt {
                    AteSearchField(prompt: searchPrompt, text: searchText)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if commit != nil { Spacer(minLength: 0) }
                if let commit {
                    AteInkPill(title: commit.title, isEnabled: commit.isEnabled, identifier: "sheet.commit",
                               action: commit.action)
                        .ateContentBottom(AteMetrics.sheetBottom)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteSheetScaffoldMetrics.titleGap)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
        .background(AtePalette.surface.ground)
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackground(AtePalette.surface.ground)
    }
}

enum AteSheetScaffoldMetrics {
    /// `.top{left:16px; right:16px; top:14px}` — the corner discs.
    static let cornerInset: CGFloat = 16
    static let cornerTop: CGFloat = 14
    /// The title's top at 72: 14 under the 44 discs.
    static let titleGap: CGFloat = 14
}

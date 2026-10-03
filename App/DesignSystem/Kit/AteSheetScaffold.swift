import AteKit
import SwiftUI

/// **The sheet scaffold** — one layout, every sheet. A native sheet (the system grabber) on the
/// control surface, in three bands:
///
/// - **The header** (``AteSheetHeader``), fixed: close as a glass disc top left, the primary action
///   (the ink tick, or Share) mirrored top right when there is one, and the title in Bricolage 800 at
///   30 under that row. Its geometry is ``SheetHeaderGeometry``'s, so no sheet can move its X.
/// - **The body**: an optional 50pt search pill in the field colour, then the content. It scrolls
///   when it outgrows the screen.
/// - **The foot**, on a sheet that applies a choice: one ink pill with a live count, pinned above the
///   home indicator, at least 24 clear of the content, never clipped. A sheet that picks one row
///   closes on the tap and has no pill.
///
/// **Sized to its content**: the sheet measures its three bands and sets one fitted detent, with
/// `.large` beside it only when the content is taller than the screen (where the body scrolls). It
/// only grows while it is up, so a list that thins out never jumps under the thumb. A caller that
/// passes `detents` (the composer, the printed receipt) takes the whole height and lays its own body.
struct AteSheetScaffold<Content: View>: View {
    typealias Primary = AteSheetPrimary
    typealias Commit = AteSheetCommit

    /// The sheet's title. `nil` on the composer, whose words start under the corner row.
    let title: String?
    var primary: Primary?
    var searchPrompt: String?
    var searchText: Binding<String>?
    var commit: Commit?
    /// `nil` fits the sheet to its content; a set takes over (and the body is not wrapped in a scroll).
    var detents: Set<PresentationDetent>?
    /// What close does; dismisses the sheet by default.
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var fit = AteSheetFit(gap: 0, bottom: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AteSheetHeader(title: title, primary: primary) {
                if let onClose { onClose() } else { dismiss() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.head = $0 }
            if detents == nil {
                ScrollView {
                    bodyBand
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.body = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                bodyBand
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let commit {
                AteInkPill(title: commit.title, isEnabled: commit.isEnabled, identifier: "sheet.commit",
                           action: commit.action)
                    .padding(.horizontal, SheetHeaderGeometry.gutter)
                    .padding(.top, AteSheetScaffoldMetrics.footTop)
                    .padding(.bottom, AteSheetScaffoldMetrics.footBottom)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.foot = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
        .background(AtePalette.surface.ground)
        .onChange(of: commit != nil, initial: true) { _, has in fit.hasFoot = has }
        .presentationDetents(detents ?? fittedDetents)
        .presentationDragIndicator(.visible)
        .presentationBackground(AtePalette.surface.ground)
    }

    /// The search pill and the content, on the gutter.
    private var bodyBand: some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            if let searchText, let searchPrompt {
                AteSearchField(prompt: searchPrompt, text: searchText)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SheetHeaderGeometry.gutter)
        .padding(.top, title == nil ? 0 : AteMetrics.sheetGap)
        .padding(.bottom, commit == nil ? AteSheetScaffoldMetrics.bareBottom : 0)
    }

    /// One detent at the measured height (above the home indicator, which the system adds); `.large`
    /// joins it only when that is taller than the screen allows. Before the first measurement, the
    /// medium detent stands in for one layout pass.
    private var fittedDetents: Set<PresentationDetent> {
        guard fit.tallest > 0 else { return [.medium] }
        let available = AteScreen.height - AteScreen.safeArea.top - AteScreen.safeArea.bottom
        return fit.tallest >= available ? [.large] : [.height(fit.tallest)]
    }
}

/// A sheet's top-right disc.
struct AteSheetPrimary {
    var icon: AteIcon
    var label: String
    var isEnabled = true
    var isBusy = false
    var action: () -> Void
}

/// A sheet's foot: the ink pill — "Show 12 entries".
struct AteSheetCommit {
    var title: String
    var isEnabled = true
    var action: () -> Void
}

/// **The one sheet header** — laid out from ``SheetHeaderGeometry``: the close disc at its fixed
/// frame, the primary disc mirrored when present, and the title from 72 on the gutter.
struct AteSheetHeader: View {
    let title: String?
    var primary: AteSheetPrimary?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SheetHeaderGeometry.titleGap) {
            HStack(spacing: 0) {
                AteGlassDisc(icon: .close, label: "Close", identifier: "sheet.close", action: onClose)
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
            .padding(.horizontal, SheetHeaderGeometry.cornerInset)
            .frame(height: SheetHeaderGeometry.disc)
            if let title {
                Text(title)
                    .ateText(.sheetTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, SheetHeaderGeometry.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.top, SheetHeaderGeometry.cornerTop)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

enum AteSheetScaffoldMetrics {
    /// The last group clears the pill by 24; the pill sits 8 above the home indicator's inset.
    static let footTop: CGFloat = 24
    static let footBottom: CGFloat = 8
    /// Under the last row of a sheet with no pill.
    static let bareBottom: CGFloat = 24
}

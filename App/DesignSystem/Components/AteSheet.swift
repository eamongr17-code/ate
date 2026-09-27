import AteKit
import SwiftUI

/// **The sheet scaffold**: control surface, 32pt top corners, the system grabber, a 30pt title, an
/// optional pill search field, content, and at most one ink pill at the bottom.
///
/// Stock `.presentationDetents` and the system grabber do the work — the design's sheets are native
/// sheets with the app's own type and colour, not a hand-built modal.
///
/// **No X** (round 4): the grabber and a swipe down dismiss, as every system sheet does. **Sized to
/// its content**: the sheet measures what it holds and sets one fitting detent, capped by the system
/// at full height (where the content scrolls). It only ever grows while it is up — a search sheet
/// whose results thin out as you type does not jump under your thumb. Callers set no detents.
struct AteSheet<Content: View>: View {
    let title: String
    /// Present on the place and dish sheets, absent on Actions.
    var searchPrompt: String?
    var searchText: Binding<String>?
    /// The one ink pill, if this sheet has a commit action at all.
    var primary: (title: String, action: () -> Void)?
    /// The pill is waiting on something (a Google result resolving): it holds still, dimmed the way
    /// every off pill in the app is, until the thing it would commit is real.
    var isPrimaryBusy = false
    @ViewBuilder var content: Content

    @Environment(\.atePalette) private var palette
    @State private var fit = AteSheetFit(gap: AteMetrics.sheetGap, bottom: AteMetrics.sheetBottom)

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                Text(title)
                    .ateText(.sheetTitle)
                    // A handle is the Actions sheet's title, and handles run long: one line, cut
                    // at its tail.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let searchText, let searchPrompt {
                    AteSearchField(prompt: searchPrompt, text: searchText)
                }
            }
            // 10 above the grabber + the grabber + the design's own 14 gap.
            .padding(.top, AteMetrics.sheetTop - 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.head = $0 }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.body = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            if let primary {
                AteButton(title: primary.title, action: primary.action)
                    .disabled(isPrimaryBusy)
                    .opacity(isPrimaryBusy ? Self.busyOpacity : 1)
                    .accessibilityIdentifier("sheet.primary")
                    // `margin-bottom:34px` — the sheet's own clearance above the home indicator.
                    .padding(.bottom, AteMetrics.sheetBottom)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit.foot = $0 }
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The design's 34 under the last thing *is* the home-indicator clearance (the artboard is
        // the whole page), so the sheet's content runs to its bottom edge rather than stopping 34
        // short of it and then adding the design's 34 again.
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: primary != nil, initial: true) { _, has in fit.hasFoot = has }
        .presentationDetents(fit.detents(bottomInset: AteScreen.safeArea.bottom))
        // The system's own sheet shape: its corners follow the display's (concentric at the bottom
        // of a partial-height sheet), which a fixed corner radius cannot. The chip colour fills
        // that shape rather than a rectangle inside it.
        .presentationBackground(palette.chip)
        .presentationDragIndicator(.visible)
    }

    /// `opacity:.35` — the Summary's off Share, the same off state.
    private static var busyOpacity: Double { 0.35 }
}

extension AteSheetFit {
    /// One detent, fitted. A height detent is measured above the home indicator, and the system adds
    /// that inset under it. Nothing measured yet: the first layout pass has not happened, and a zero
    /// detent would present a sliver, so the medium detent stands in for that one pass.
    func detents(bottomInset: CGFloat) -> Set<PresentationDetent> {
        guard tallest > 0 else { return [.medium] }
        return [.height(tallest - bottomInset)]
    }
}

/// A pill search field. The design's only text input outside the composer.
struct AteSearchField: View {
    let prompt: String
    @Binding var text: String
    /// A sheet's field is 50 on the surface's `field`; `Search`'s own is 52 on `chip` with a wider
    /// inset. Both are in the markup, so both are here.
    var height: CGFloat = AteMetrics.fieldHeight
    var horizontalPadding: CGFloat = AteMetrics.loose
    var background: Color?
    /// 600 in a sheet, 500 in `Search` — the two artboards differ, so the field takes its voice.
    var textStyle: AteTextStyle = .rowTitle

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            AteIcon.search.view(size: 18)
            TextField(text: $text) {
                Text(prompt).foregroundStyle(palette.muted)
            }
            .ateText(textStyle)
            .textFieldStyle(.plain)
            .foregroundStyle(palette.fg)
            .submitLabel(.search)
        }
        .padding(.horizontal, horizontalPadding)
        .atePillHeight(height)
        .background(background ?? palette.field, in: .capsule)
    }
}

#if DEBUG
private struct SheetPreview: View {
    @State private var isPresented = true
    @State private var query = ""
    @State private var picked = 0

    var body: some View {
        Color.clear
            .ateGround()
            .sheet(isPresented: $isPresented) {
                AteSheet(
                    title: "Which place?",
                    searchPrompt: "Search places",
                    searchText: $query,
                    primary: ("Use this place", {})
                ) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { index in
                            AteRadioRow(
                                title: ["Tipo 00", "Kisume", "Butchers Diner", "400 Gradi"][index],
                                subtitle: "Melbourne",
                                isSelected: picked == index
                            ) { picked = index }
                        }
                    }
                }
            }
    }
}

#Preview("Sheet") { SheetPreview() }
#endif

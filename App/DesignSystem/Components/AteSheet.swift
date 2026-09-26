import SwiftUI

/// **The sheet scaffold**: control surface, 32pt top corners, the system grabber, a 30pt title, an
/// optional pill search field, content, and at most one ink pill at the bottom.
///
/// Stock `.presentationDetents` and the system grabber do the work — the design's sheets are native
/// sheets with the app's own type and colour, not a hand-built modal.
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .ateText(.sheetTitle)
                    // A handle is the Actions sheet's title, and handles run long: one line, cut
                    // at its tail, never under the X.
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AteMetrics.snug)
                // The design puts an X beside every sheet title. The grabber alone is a gesture;
                // the X is the affordance, and both are native.
                AteIconButton(icon: .close, label: "Close") { dismiss() }
                    .padding(.trailing, -10)
            }
            // 10 above the grabber + the grabber + the design's own 14 gap.
            .padding(.top, AteMetrics.sheetTop - 8)
            if let searchText, let searchPrompt {
                AteSearchField(prompt: searchPrompt, text: searchText)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if let primary {
                AteButton(title: primary.title, action: primary.action)
                    .disabled(isPrimaryBusy)
                    .opacity(isPrimaryBusy ? Self.busyOpacity : 1)
                    .accessibilityIdentifier("sheet.primary")
                    // `margin-bottom:34px` — the sheet's own clearance above the home indicator.
                    .padding(.bottom, AteMetrics.sheetBottom)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The system's own sheet shape: its corners follow the display's (concentric at the bottom
        // of a partial-height sheet), which a fixed corner radius cannot. The chip colour fills
        // that shape rather than a rectangle inside it.
        .presentationBackground(palette.chip)
        .presentationDragIndicator(.visible)
    }

    /// `opacity:.35` — the Summary's off Share, the same off state.
    private static var busyOpacity: Double { 0.35 }
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
        .frame(height: height)
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
                .presentationDetents([.large])
            }
    }
}

#Preview("Sheet") { SheetPreview() }
#endif

import SwiftUI

/// **The search field across the header row** (`lists-notifications.html` 2A, `.sfield`): a 44pt
/// Liquid Glass capsule holding the magnifier and the words, with the close disc beside it. It takes
/// the row the wordmark and the glass group stood in; the close disc ends the search.
///
/// `.sfield{height:44px; radius:999; gap:8px; padding:0 14px; 600 17px/1}`, its prompt muted at 500,
/// the magnifier 18; `.nav{gap:10px}`.
struct AteGlassSearchField: View {
    @Binding var text: String
    let prompt: String
    var identifier = "search.field"
    let onSubmit: () -> Void
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteGlassSearchFieldMetrics.rowGap) {
            HStack(spacing: AteGlassSearchFieldMetrics.gap) {
                AteIcon.search.view(size: AteGlassSearchFieldMetrics.glyph)
                    .foregroundStyle(palette.fg)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(prompt)
                            .ateText(.kitListRow)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text)
                        .ateText(.kitEndRow)
                        .foregroundStyle(palette.fg)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .onSubmit(onSubmit)
                        .accessibilityLabel(prompt)
                        .accessibilityIdentifier(identifier)
                }
            }
            .padding(.horizontal, AteGlassSearchFieldMetrics.padding)
            .frame(height: AteMetrics.hit)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
            .onTapGesture { isFocused = true }
            AteGlassDisc(icon: .close, label: "Close", identifier: "\(identifier).close", action: onClose)
        }
        .onAppear { isFocused = true }
    }
}

enum AteGlassSearchFieldMetrics {
    static let gap: CGFloat = 8
    static let padding: CGFloat = 14
    static let glyph: CGFloat = 18
    static let rowGap: CGFloat = 10
}

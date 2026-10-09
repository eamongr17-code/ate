import SwiftUI

/// **The ink pill** — the one commit button. A sheet that applies a choice ends in one, full width,
/// 52 high, often carrying a live count ("Show 12 entries"); an empty state has at most one, 44 high,
/// hugging its words. Ink in light, the dimmed cream in dark (``AtePalette/solid``). Nothing else in
/// the app is a filled button — but a list's page pairs it with one quiet sibling, in the field colour
/// (``isQuiet``), as a playlist pairs Play with Shuffle (`lists-playlists.html` `.acts`).
struct AteInkPill: View {
    enum Size: Equatable {
        /// A sheet's foot: 52, full width, Bricolage 600 at 16.
        case sheet
        /// An empty state: 44, `padding:0 24px`, Bricolage 600 at 15.
        case empty
    }

    let title: String
    var size: Size = .sheet
    var isEnabled = true
    /// The field colour with ink lettering: the second of a pair, never on its own.
    var isQuiet = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(size == .sheet ? .kitInkPill : .kitInkPillSmall)
                .lineLimit(1)
                .padding(.horizontal, size == .sheet ? AteInkPillMetrics.sheetPadding : AteInkPillMetrics.emptyPadding)
                .frame(maxWidth: size == .sheet ? .infinity : nil)
                .frame(height: size == .sheet ? AteInkPillMetrics.sheetHeight : AteInkPillMetrics.emptyHeight)
                .foregroundStyle(isQuiet ? palette.fg : palette.inverted)
                .background(isQuiet ? palette.field : palette.solid, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .accessibilityIdentifier(identifier ?? "pill.\(title)")
    }
}

enum AteInkPillMetrics {
    static let sheetHeight: CGFloat = 52
    static let sheetPadding: CGFloat = 20
    static let emptyHeight: CGFloat = 44
    static let emptyPadding: CGFloat = 24
}

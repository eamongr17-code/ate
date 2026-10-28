import SwiftUI

/// **The ink pill** — the one commit button. A sheet that applies a choice ends in one, full width,
/// 52 high, often carrying a live count ("Show 12 entries"); an empty state has at most one, 44 high,
/// hugging its words. Ink in light, the dimmed cream in dark (``AtePalette/solid``). Nothing else in
/// the app is a filled button — but a list's page pairs it with one quiet sibling, in the field colour
/// (``isQuiet``), as a playlist pairs Play with Shuffle (`lists-playlists.html` `.acts`).
struct AteInkPill: View {
    enum Size: Equatable {
        /// A sheet's foot: 52, full width, DM Sans 600 at 16.
        case sheet
        /// An empty state: 44, `padding:0 24px`, DM Sans 600 at 15.
        case empty
        /// Answering inside a row (a list invite's Accept): `.pill.sm`, 38, `padding:0 18px`, 600 at 14.
        case row
    }

    let title: String
    var size: Size = .sheet
    var isEnabled = true
    /// The field colour with ink lettering: the second of a pair, never on its own.
    var isQuiet = false
    /// A glyph before the words: an entry's "Add to a list" (`journal-dish-to-list.html` B).
    var icon: AteIcon?
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteInkPillMetrics.iconGap) {
                if let icon {
                    icon.view(size: AteInkPillMetrics.icon)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .ateText(textStyle)
                    .lineLimit(1)
            }
                .padding(.horizontal, padding)
                .frame(maxWidth: size == .sheet ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(isQuiet ? palette.fg : palette.inverted)
                .background(isQuiet ? palette.field : palette.solid, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .accessibilityIdentifier(identifier ?? "pill.\(title)")
    }

    private var textStyle: AteTextStyle {
        switch size {
        case .sheet: .kitInkPill
        case .empty: .kitInkPillSmall
        case .row: .kitInkPillRow
        }
    }

    private var padding: CGFloat {
        switch size {
        case .sheet: AteInkPillMetrics.sheetPadding
        case .empty: AteInkPillMetrics.emptyPadding
        case .row: AteInkPillMetrics.rowPadding
        }
    }

    private var height: CGFloat {
        switch size {
        case .sheet: AteInkPillMetrics.sheetHeight
        case .empty: AteInkPillMetrics.emptyHeight
        case .row: AteInkPillMetrics.rowHeight
        }
    }
}

enum AteInkPillMetrics {
    static let sheetHeight: CGFloat = 52
    static let sheetPadding: CGFloat = 20
    static let emptyHeight: CGFloat = 44
    static let emptyPadding: CGFloat = 24
    static let rowHeight: CGFloat = 38
    static let rowPadding: CGFloat = 18
    static let icon: CGFloat = 20
    static let iconGap: CGFloat = 10
}

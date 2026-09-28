import SwiftUI

/// **A tab root's compact header** (round 6) — what comes back over the list on a scroll up, in
/// place of a second copy of the big header. Eamon: "there should be a reduced-size header variant
/// used whenever it's showing just in scrolls."
///
/// The tab's name, small — or on the Journal the month you are scrolled to, its year muted beside it
/// ("August 2026", `JournalScrolled`) — and the controls the big header carries at its end, in one row
/// just under the status bar. It has no surface of its own: it sits on the one top frost
/// (``AteTopFrost``), which runs from the screen's top edge down through it and feathers out below.
/// The title leads; the controls trail (round 6, Eamon's pick).
struct AteCompactHeader<Trailing: View>: View {
    let title: String
    /// Muted after the title — the Journal month's year.
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        row
            .padding(.horizontal, AteMetrics.listGutter)
            .frame(maxWidth: .infinity)
            .frame(height: AteCompactHeaderMetrics.row)
    }

    private var row: some View {
        HStack(spacing: AteMetrics.snug) {
            titleText
            Spacer(minLength: AteMetrics.snug)
            trailing
        }
    }

    private var titleText: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteCompactHeaderMetrics.titleGap) {
            Text(title)
                .ateTextLine(.compactTitle)
                .foregroundStyle(AtePalette.automatic.fg)
            if let subtitle {
                Text(subtitle)
                    .ateTextLine(.compactTitleYear)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("compact.title")
    }
}

enum AteCompactHeaderMetrics {
    /// The row under the status bar: the tallest control it carries (a 40 chip, a 44 hit) and air.
    static let row: CGFloat = 52
    /// A space's width between the month and its year.
    static let titleGap: CGFloat = 5
    /// Between the controls at its end (`JournalScrolled`: `gap: 10px`).
    static let controlGap: CGFloat = 10
}

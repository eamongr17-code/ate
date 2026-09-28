import AteKit
import SwiftUI

/// **A chip's sheet** (round 7, `RatingChip`) — small, fitted to what it holds: the chip's name and
/// the choice read out on the right, its control, and at the foot a muted Clear beside one ink pill,
/// "Show 23 entries", counted live as the choice changes. Nothing is applied until that pill; a swipe
/// down leaves the list as it was.
///
/// A native sheet: the system's grabber, its drag to dismiss, its corners set to the artboard's 34.
struct AteChipSheet<Content: View>: View {
    let title: String
    /// The choice as it stands: "4.0 and up", "Everywhere".
    let value: String
    /// What the pill will show — `nil` while it is being counted, or where it cannot be.
    let count: Int?
    /// "entry"/"entries" on the Journal, "dish"/"dishes" on Saved.
    var noun = AteChipSheetNoun.entries
    let onClear: () -> Void
    let onShow: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.atePalette) private var palette
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: AteChipSheetMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(title)
                    .ateText(.chipSheetTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AteMetrics.snug)
                Text(value)
                    .ateText(.chipSheetValue)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("chipsheet.value")
            }
            .foregroundStyle(palette.fg)
            content
            foot
        }
        .padding(.horizontal, AteChipSheetMetrics.side)
        .padding(.top, AteChipSheetMetrics.top)
        .padding(.bottom, AteChipSheetMetrics.bottom)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .bottom)
        .presentationDetents(detents)
        .presentationCornerRadius(AteChipSheetMetrics.corner)
        .presentationBackground(palette.chip)
        .presentationDragIndicator(.visible)
        .environment(\.atePalette, .surface)
    }

    /// One detent, the sheet's own height. A height detent is measured above the home indicator.
    private var detents: Set<PresentationDetent> {
        guard height > 0 else { return [.medium] }
        return [.height(height - AteScreen.safeArea.bottom)]
    }

    private var foot: some View {
        HStack(spacing: AteMetrics.regular) {
            Button(action: onClear) {
                Text("Clear")
                    .ateText(.chipSheetClear)
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, 18)
                    .frame(height: AteChipSheetMetrics.button)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chipsheet.clear")
            Button(action: onShow) {
                Text(showTitle)
                    .ateText(.chipSheetAction)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(palette.inverted)
                    .frame(maxWidth: .infinity)
                    .frame(height: AteChipSheetMetrics.button)
                    .background(palette.solid, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chipsheet.show")
        }
        .padding(.top, AteChipSheetMetrics.footTop)
        .ateAnimation(AteMotion.scoreRoll, value: count)
    }

    private var showTitle: String {
        guard let count else { return "Show \(noun.plural)" }
        return "Show \(count) \(count == 1 ? noun.singular : noun.plural)"
    }
}

struct AteChipSheetNoun: Sendable {
    let singular: String
    let plural: String

    static let entries = AteChipSheetNoun(singular: "entry", plural: "entries")
    static let dishes = AteChipSheetNoun(singular: "dish", plural: "dishes")
}

enum AteChipSheetMetrics {
    /// `padding: 12px 22px 40px; gap: 20px; border-radius: 34px 34px 0 0` — the grabber's 12 and 5
    /// above the title are the system's own, so the title starts 37 down.
    static let side: CGFloat = 22
    static let top: CGFloat = 37
    static let bottom: CGFloat = 40
    static let gap: CGFloat = 20
    static let corner: CGFloat = 34
    /// The foot's two buttons: 52 tall, 6 more above them.
    static let button: CGFloat = 52
    static let footTop: CGFloat = 6
}

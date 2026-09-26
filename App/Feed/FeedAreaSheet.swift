import AteKit
import SwiftUI

/// **Which area the feed is about** — the sheet behind the Feed's location pill.
///
/// The app's own sheet (``AteSheet``): a title, radio rows, no pill button — a radio row *is* the
/// answer, so picking one closes the question. "Everywhere" leads; then every area people have
/// written about, busiest first, each with how many entries it holds — paged as it scrolls.
struct FeedAreaSheet: View {
    let model: FeedAreaModel
    let onChoose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(title: "Which area?") {
            VStack(spacing: 0) {
                AteRadioRow(title: "Everywhere", isSelected: model.selected == nil) { choose(nil) }
                ForEach(rows) { area in
                    AteRadioRow(
                        title: area.area,
                        subtitle: Self.entries(area.count),
                        isSelected: model.selected == area.area
                    ) { choose(area.area) }
                    // Paged (0038: keyset `entry_count desc, area asc`): the next page as the end nears.
                    .task { await model.loadMoreAreasIfNeeded(after: area) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.loadAreas() }
    }

    /// The areas, plus the remembered choice if it has dropped off the list — it is still the
    /// reader's, and it must still be visibly the one that is ticked.
    private var rows: [FeedArea] {
        guard let selected = model.selected, model.areas.contains(where: { $0.area == selected }) == false
        else { return model.areas }
        return model.areas + [FeedArea(area: selected, count: 0)]
    }

    private func choose(_ area: String?) {
        onChoose(area)
        dismiss()
    }

    /// "12 entries" — nothing at all for none, rather than a zero.
    private static func entries(_ count: Int) -> String? {
        guard count >= 1 else { return nil }
        return count == 1 ? "1 entry" : "\(count.formatted()) entries"
    }
}

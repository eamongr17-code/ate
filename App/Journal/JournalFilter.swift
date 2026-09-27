import AteKit
import SwiftUI

// MARK: - The pills

extension JournalQuery {
    /// The active filters as the row under the control draws them.
    var activeFilters: [AteActiveFilter] {
        pills.map { AteActiveFilter(id: $0.id, title: $0.title) }
    }

    /// The query without the pill the reader took away.
    func removing(_ filter: AteActiveFilter) -> JournalQuery {
        guard let pill = pills.first(where: { $0.id == filter.id }) else { return self }
        return removing(pill)
    }
}

// MARK: - Month markers

/// **A quiet month marker** — while the journal scrolls, the month of the entries at the top of the
/// screen, small, on glass, at the top; gone a moment after the list comes to rest. Only when the
/// list runs through time.
struct JournalMonthMarker: View {
    let title: String

    var body: some View {
        Text(title)
            .ateText(.meta)
            .foregroundStyle(AtePalette.automatic.fg)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .ateGlass(in: Capsule()) // the chrome's glass (round 5), not the system's
            .accessibilityHidden(true)
    }
}

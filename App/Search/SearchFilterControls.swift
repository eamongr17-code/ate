import AteKit
import SwiftUI

/// Search's filters as the one filter row draws them (``AteActiveFilters``) — the same pills as the
/// Journal's.
extension SearchFilters {
    /// The active filters as the row under the control draws them.
    var activeFilters: [AteActiveFilter] {
        pills.map { AteActiveFilter(id: $0.id, title: $0.title) }
    }

    func removing(_ filter: AteActiveFilter) -> SearchFilters {
        guard let pill = pills.first(where: { $0.id == filter.id }) else { return self }
        return removing(pill)
    }
}

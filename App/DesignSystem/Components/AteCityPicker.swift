import AteKit
import SwiftUI

/// One answer in the city picker: a city, Everywhere, or the Feed's Near me.
struct AteCityOption: Identifiable, Hashable {
    /// The slug, or a reserved word (`@everywhere`, `@near-me`) — whatever the caller keys on.
    let id: String
    let title: String
    /// Near me's mark.
    var icon: AteIcon?

    static let everywhereID = "@everywhere"
    static let everywhere = AteCityOption(id: everywhereID, title: "Everywhere")
}

extension AteCityOption {
    /// The options for a list of cities, Everywhere first — and the current choice kept on the list
    /// when it has dropped off it (it is still the reader's, and still visibly the one that is on).
    static func cities(_ cities: [AteCity], keeping selected: String?, named name: String? = nil) -> [AteCityOption] {
        var options = [AteCityOption.everywhere] + cities.map { AteCityOption(id: $0.city, title: $0.name) }
        if let selected, options.contains(where: { $0.id == selected }) == false {
            options.append(AteCityOption(id: selected, title: name ?? AteCity.displayName(for: selected)))
        }
        return options
    }
}

import AteKit
import SwiftUI

/// **Where the Feed is about** — the pin's sheet (build 88: every chooser in the app is a sheet, so
/// the area is one too, not a pull-down menu). The kit's sheet, fitted to its rows: Near me,
/// Everywhere, then every city with food, busiest first, the current one marked. A row is the
/// answer: a tap hands back the location and the sheet closes; the root does the rest (Near me asks
/// for the location there, and nowhere else). The search pill narrows the rows as you type (Eamon,
/// 6 Oct: "the location button should allow search").
struct FeedAreaSheet: View {
    let area: FeedAreaModel
    let onPick: (FeedLocation) -> Void

    static let title = "Where?"
    static let nearMeTitle = "Near me"
    static let everywhereTitle = "Everywhere"
    static let searchPrompt = "Search cities"
    static let noMatch = "No city\nlike that."

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(title: Self.title, searchPrompt: Self.searchPrompt, searchText: $query) {
            let matches = AteCity.matching(cities, query: query)
            let showsNearMe = AteCity.title(Self.nearMeTitle, matches: query)
            let showsEverywhere = AteCity.title(Self.everywhereTitle, matches: query)
            if matches.isEmpty, showsNearMe == false, showsEverywhere == false {
                AteEmptyState(line: Self.noMatch, art: .search)
                    .frame(minHeight: AteEmptyStateMetrics.sheetMinimum)
                    .accessibilityIdentifier("area.noMatch")
            } else {
                VStack(spacing: 0) {
                    if showsNearMe { row(Self.nearMeTitle, .nearMe, identifier: "area.nearMe") }
                    if showsEverywhere { row(Self.everywhereTitle, .everywhere, identifier: "area.everywhere") }
                    ForEach(matches) { city in
                        row(city.name, .city(city.city), identifier: "area.city.\(city.city)")
                    }
                }
            }
        }
        .accessibilityIdentifier("feed.area.sheet")
    }

    private func row(_ title: String, _ location: FeedLocation, identifier: String) -> some View {
        AteChoiceRow(title: title, isSelected: area.location == location, identifier: identifier) {
            dismiss()
            onPick(location)
        }
    }

    /// Every city with food, busiest first — and the one the Feed is on, should the list not hold it.
    private var cities: [AteCity] {
        var cities = area.cities
        if case .city(let slug) = area.location, cities.contains(where: { $0.city == slug }) == false {
            cities.insert(AteCity(city: slug, name: area.locationTitle), at: 0)
        }
        return cities
    }
}

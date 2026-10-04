import AteKit
import SwiftUI

/// **Where the Feed is about** — the pin's sheet (build 88: every chooser in the app is a sheet, so
/// the area is one too, not a pull-down menu). The kit's sheet, fitted to its rows: Near me,
/// Everywhere, then every city with food, busiest first, the current one marked. A row is the
/// answer: a tap hands back the location and the sheet closes; the root does the rest (Near me asks
/// for the location there, and nowhere else).
struct FeedAreaSheet: View {
    let area: FeedAreaModel
    let onPick: (FeedLocation) -> Void

    static let title = "Where?"
    static let nearMeTitle = "Near me"
    static let everywhereTitle = "Everywhere"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(title: Self.title) {
            VStack(spacing: 0) {
                row(Self.nearMeTitle, .nearMe, identifier: "area.nearMe")
                row(Self.everywhereTitle, .everywhere, identifier: "area.everywhere")
                ForEach(cities) { city in
                    row(city.name, .city(city.city), identifier: "area.city.\(city.city)")
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

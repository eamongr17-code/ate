import AteKit
import SwiftUI

/// **Where the Feed is about** — the pin's native Menu, holding what the current build's Where?
/// sheet holds: Near me, Everywhere, then every city with food, busiest first, the current one
/// ticked. One choice, so a menu (pattern contract §2). A pick hands back the location; the root
/// does the rest (Near me asks for the location there, and nowhere else).
struct FeedAreaMenu: View {
    let area: FeedAreaModel
    let onPick: (FeedLocation) -> Void

    static let nearMeTitle = "Near me"
    private static let nearMeID = "@near-me"
    private static let everywhereID = "@everywhere"

    var body: some View {
        Picker("Area", selection: Binding(get: { selection }, set: { onPick(Self.location(of: $0)) })) {
            Text(Self.nearMeTitle).tag(Self.nearMeID)
            Text("Everywhere").tag(Self.everywhereID)
            ForEach(cities) { city in
                Text(city.name).tag(city.city)
            }
        }
        .pickerStyle(.inline)
    }

    /// Every city with food, busiest first — and the one the Feed is on, should the list not hold it.
    private var cities: [AteCity] {
        var cities = area.cities
        if case .city(let slug) = area.location, cities.contains(where: { $0.city == slug }) == false {
            cities.insert(AteCity(city: slug, name: area.locationTitle), at: 0)
        }
        return cities
    }

    private var selection: String {
        switch area.location {
        case .nearMe: Self.nearMeID
        case .everywhere: Self.everywhereID
        case .city(let slug): slug
        }
    }

    private static func location(of id: String) -> FeedLocation {
        switch id {
        case nearMeID: .nearMe
        case everywhereID: .everywhere
        default: .city(id)
        }
    }
}

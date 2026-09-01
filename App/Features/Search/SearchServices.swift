import AteKit
import Foundation
import TelemetryDeck

/// Everything ``SearchPicker`` needs from the outside world, in one value.
///
/// Not a DI container — just the three seams (restaurants, dishes, telemetry) bundled so a caller
/// wires them once and every nested picker inherits them. `live(api:)` is what the app uses;
/// the protocol types are what previews and tests substitute.
struct SearchServices: Sendable {
    let restaurants: any RestaurantSearchProviding
    let dishes: any DishSearchProviding
    let telemetry: any SearchTelemetrySink

    init(
        restaurants: any RestaurantSearchProviding,
        dishes: any DishSearchProviding,
        telemetry: any SearchTelemetrySink = TelemetryDeckSearchSink()
    ) {
        self.restaurants = restaurants
        self.dishes = dishes
        self.telemetry = telemetry
    }

    static func live(api: AteAPIClient) -> SearchServices {
        SearchServices(
            restaurants: RestaurantSearchService(api: api),
            dishes: DishSearchService(api: api)
        )
    }
}

/// The only untestable part of the telemetry path: handing a resolved signal to the SDK.
struct TelemetryDeckSearchSink: SearchTelemetrySink {
    func send(_ event: SearchEvent) {
        TelemetryDeck.signal(event.name, parameters: event.parameters)
    }
}

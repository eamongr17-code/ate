import Foundation
import Observation

/// **The dish map** (`nearby-map.html`, option A, approved 25 Oct): the pins in view and the sheet
/// under them — "Dishes near you", best first — or, with a pin tapped, that place.
///
/// The map opens framed on the phone and the nearest ``openingPlaces`` places with dishes, however
/// far, so it is never empty with a beta's coverage (``open()`` sets ``frame``). After that it reads
/// only what is on screen, once the map stops moving (``show(_:)``); a read that comes back after a
/// newer one was asked for is dropped, so a fast pan never paints an old area.
@MainActor
@Observable
public final class DishMapStore {
    public enum Phase: Sendable, Equatable {
        case opening
        case ready
        /// The read never came back. The map stays; the sheet offers another try.
        case failed
    }

    /// How many places the map opens framed on.
    public static let openingPlaces = 10
    /// Pins per read: plenty for a city screen, and the server's own cap is 200.
    public static let placesPerRead = 150
    public static let dishesPerPage = 20

    public private(set) var phase: Phase = .opening
    /// Where the map should look. Set once by ``open()``; the view moves the camera to it.
    public private(set) var frame: MapBox?
    /// The phone, when the permission is given.
    public private(set) var phone: SearchOrigin?
    /// The pins in view, nearest the middle first.
    public private(set) var places: [MapPlace] = []
    /// "Dishes near you": every dish at those places, best first, paged.
    public private(set) var dishes: [MapDish] = []
    public private(set) var hasMoreDishes = false
    /// The tapped pin.
    public private(set) var selected: MapPlace?
    /// The tapped place's dishes, best first — the place page's own menu read (`place_dishes`), its
    /// first page. Empty while it loads.
    public private(set) var selectedMenu: [MenuDish] = []
    /// The suburb under the map's centre, for the title once the map is off you.
    public var area: String?
    /// What the map shows now.
    public private(set) var box: MapBox?

    private let reads: any DishMapReading
    private let menus: any PlacePageReading
    private let locate: NearbyPlaces.Locate
    private let analytics: AnalyticsRecorder
    private var generation = 0
    private var nextCursor: MapDishCursor?
    private var isLoadingMore = false

    public init(
        reads: any DishMapReading,
        menus: any PlacePageReading,
        locate: @escaping NearbyPlaces.Locate,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.reads = reads
        self.menus = menus
        self.locate = locate
        self.analytics = analytics
    }

    public var title: DishMapTitle {
        guard let box else { return .nearYou }
        return DishMapTitle.resolve(box: box, phone: phone, area: area)
    }

    /// Finds the phone (asking for the permission the first time) and frames the map on it and the
    /// nearest places with dishes. With no permission, around the place most written about.
    public func open() async {
        guard frame == nil else { return }
        analytics(MapEvents.opened())
        phase = .opening
        let phone = await locate(true)
        self.phone = phone
        do {
            let nearest = try await reads.nearest(to: phone, limit: Self.openingPlaces)
            let points = nearest.map(\.origin) + (phone.map { [$0] } ?? [])
            frame = MapBox.fitting(points) ?? phone.map {
                MapBox(centerLatitude: $0.latitude, centerLongitude: $0.longitude,
                       latitudeDelta: 0.03, longitudeDelta: 0.03)
            }
            // The framing read already has the pins; the first `show` after the camera lands replaces them.
            places = nearest
            // Nothing anywhere has a place on the map: an empty, settled sheet, not a spinner.
            if frame == nil { phase = .ready }
        } catch {
            phase = .failed
        }
    }

    /// The map stopped moving on `box`: read its pins and the first page of its dishes.
    public func show(_ box: MapBox) async {
        self.box = box
        generation += 1
        let mine = generation
        do {
            async let pins = reads.places(in: box, origin: phone, limit: Self.placesPerRead)
            async let first = reads.dishes(in: box, origin: phone, after: nil, pageSize: Self.dishesPerPage)
            let (newPlaces, page) = try await (pins, first)
            guard mine == generation else { return }
            places = newPlaces
            dishes = page.items
            nextCursor = page.nextCursor
            hasMoreDishes = page.nextCursor != nil
            if let selected, newPlaces.contains(where: { $0.id == selected.id }) == false {
                self.selected = nil
                selectedMenu = []
            }
            phase = .ready
        } catch {
            guard mine == generation else { return }
            phase = .failed
        }
    }

    /// The next page of the sheet, when the list reaches its end.
    public func loadMoreDishes() async {
        guard let box, let cursor = nextCursor, isLoadingMore == false else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = generation
        guard let page = try? await reads.dishes(in: box, origin: phone, after: cursor, pageSize: Self.dishesPerPage),
              mine == generation else { return }
        let seen = Set(dishes.map(\.id))
        dishes += page.items.filter { seen.contains($0.id) == false }
        nextCursor = page.nextCursor
        hasMoreDishes = page.nextCursor != nil
    }

    /// Another go after a failed read.
    public func retry() async {
        if frame == nil {
            await open()
        } else if let box {
            await show(box)
        }
    }

    /// A pin or a dot was tapped: it grows into its photos and the sheet becomes that place, with its
    /// dishes. Tapping it again (or `nil`) lets it go.
    public func select(_ place: MapPlace?) async {
        guard let place, place.id != selected?.id else {
            selected = nil
            selectedMenu = []
            return
        }
        selected = place
        selectedMenu = []
        analytics(MapEvents.placeSelected(dishCount: place.dishCount))
        let menu = try? await menus.placeDishes(
            restaurantID: place.restaurantID, after: nil, pageSize: Self.dishesPerPage
        )
        guard selected?.id == place.id else { return }
        selectedMenu = menu?.items ?? []
    }

    /// The Show my location button: the phone back in the middle (the view moves the camera).
    public func recentre() async -> SearchOrigin? {
        guard let fix = await locate(true) else { return nil }
        phone = fix
        analytics(MapEvents.recentred())
        return fix
    }
}

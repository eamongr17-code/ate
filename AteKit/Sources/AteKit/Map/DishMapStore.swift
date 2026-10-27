import Foundation
import Observation

/// **The dish map** (`nearby-map-2.html`, round 2 after build 214): the pins in view and the sheet
/// under them.
///
/// The map opens on ``nearRadius`` around the phone (``open()`` sets ``frame``), and the sheet lists
/// **Near me**: every dish within that radius, best first. The sheet holds still while the map
/// moves; only the pins follow the camera (``show(_:)``). Once the map is somewhere else, Search here
/// (``canSearchHere``, ``searchHere()``) lists what is on screen, titled with its suburb, and the
/// location button comes back to Near me (``backToNearMe()``). A read that lands after a newer one
/// was asked for is dropped, so a fast pan never paints an old area. A list on show stays, rows and
/// title, until the next one lands with its suburb: only an empty sheet shows placeholders.
@MainActor
@Observable
public final class DishMapStore {
    public enum Phase: Sendable, Equatable {
        case opening
        case ready
        /// The read never came back. The map stays; the sheet offers another try.
        case failed
        /// No connection: the phone is offline, or the read has had no answer for ``stallSeconds``.
        /// The read carries on, and the sheet fills by itself if it lands or the connection returns.
        case offline
    }

    /// What the sheet lists.
    public enum Listing: Sendable, Equatable {
        /// Every dish within ``nearRadius`` of the phone.
        case nearMe(SearchOrigin)
        /// Every dish at the places in a box: Search here, or the opening view with location off.
        case area(MapBox)

        /// An area to name, Near me needs none.
        var area: MapBox? {
            if case .area(let box) = self { return box }
            return nil
        }

        public var box: MapBox {
            switch self {
            case .nearMe(let phone): MapBox.around(phone, radiusMeters: DishMapStore.nearRadius)
            case .area(let box): box
            }
        }
    }

    /// Near me, and the map's opening view: 2 km around the phone (Eamon, 25 Oct, after build 215).
    public nonisolated static let nearRadius: Double = 2_000
    /// Pins per read: plenty for a city screen, and the server's own cap is 200.
    public static let placesPerRead = 150
    public static let dishesPerPage = 20
    /// A Near me page can come back with every row past the radius (the box's corners); this many
    /// pages are read on before the list settles for what it has.
    static let pagesPerFill = 5

    /// The sheet's list.
    public private(set) var phase: Phase = .opening
    /// Where the camera should go. Set by ``open()``; the view moves the camera to it.
    public private(set) var frame: MapBox?
    /// The phone, when the permission is given.
    public private(set) var phone: SearchOrigin?
    /// The pins in view, nearest the middle first.
    public private(set) var places: [MapPlace] = []
    /// What the sheet lists, and the dishes in it, best first, paged.
    public private(set) var listing: Listing?
    public private(set) var dishes: [MapDish] = []
    public private(set) var hasMoreDishes = false
    /// The sheet's title: the list on show's, so it changes with the rows, never before them.
    public private(set) var title: DishMapTitle = .nearMe
    /// The tapped pin.
    public private(set) var selected: MapPlace?
    /// The tapped place's dishes, best first — the place page's own menu read (`place_dishes`), its
    /// first page. Empty while it loads.
    public private(set) var selectedMenu: [MenuDish] = []
    /// What the map shows now.
    public private(set) var box: MapBox?

    private let reads: any DishMapReading
    private let menus: any PlacePageReading
    private let locate: NearbyPlaces.Locate
    private let nameArea: NameArea
    private let analytics: AnalyticsRecorder
    private var pinGeneration = 0
    private var listGeneration = 0
    private var nextCursor: MapDishCursor?
    private var isLoadingMore = false
    /// A list read is out: placeholders on an empty sheet, the old list kept on a full one.
    private var isListing = false
    /// A list read with no answer after this long says No connection (build 217: a ~17 s dropout
    /// sat on placeholders with nothing said).
    private let stallSeconds: Double
    private var isOnline = true
    /// What the last pins read asked for, to ask again when the connection returns.
    private var lastShown: (box: MapBox, reading: MapBox?)?
    /// Near me's first page, as last read: the location button brings it back without a read.
    private var lastNearMe: KeptNearMe?

    private struct KeptNearMe {
        let phone: SearchOrigin
        let dishes: [MapDish]
        let next: MapDishCursor?
    }

    /// The suburb in the middle of a box ("Carlton"), or `nil` (over water, or no answer).
    public typealias NameArea = @Sendable (MapBox) async -> String?

    public init(
        reads: any DishMapReading,
        menus: any PlacePageReading,
        locate: @escaping NearbyPlaces.Locate,
        nameArea: @escaping NameArea = { _ in nil },
        analytics: @escaping AnalyticsRecorder = { _ in },
        stallSeconds: Double = 8
    ) {
        self.stallSeconds = stallSeconds
        self.reads = reads
        self.menus = menus
        self.locate = locate
        self.nameArea = nameArea
        self.analytics = analytics
    }

    /// The map has moved far enough from what the sheet lists that Search here is worth offering:
    /// its middle has left the listed area's middle half, or it has zoomed well in or out.
    public var canSearchHere: Bool {
        guard let box, let listed = listing?.box else { return false }
        let across = abs(box.centerLongitude - listed.centerLongitude) / listed.longitudeDelta
        let down = abs(box.centerLatitude - listed.centerLatitude) / listed.latitudeDelta
        let zoom = box.latitudeDelta / listed.latitudeDelta
        return across > 0.25 || down > 0.25 || zoom > 1.8 || zoom < 0.4
    }

    /// Finds the phone (asking for the permission the first time), frames the map on 2 km around it
    /// and lists Near me. With no permission, around the place most written about, listing that area.
    public func open() async {
        guard frame == nil else { return }
        analytics(MapEvents.opened())
        phase = .opening
        let phone = await locate(true)
        self.phone = phone
        if let phone {
            frame = MapBox.around(phone, radiusMeters: Self.nearRadius)
            await list(.nearMe(phone))
            return
        }
        do {
            guard let busiest = try await reads.nearest(to: nil, limit: 1).first else {
                // Nothing anywhere has a place on the map: an empty, settled sheet, not a spinner.
                phase = .ready
                return
            }
            let around = MapBox.around(busiest.origin, radiusMeters: Self.nearRadius)
            frame = around
            await list(.area(around))
        } catch {
            phase = .failed
        }
    }

    /// The map stopped moving on `box` (what is on screen, clear of the sheet): read its pins, from
    /// `reading` when the view reads past the screen's edges. The sheet stays as it is.
    public func show(_ box: MapBox, reading: MapBox? = nil) async {
        self.box = box
        lastShown = (box, reading)
        pinGeneration += 1
        let mine = pinGeneration
        let read = reading ?? box
        guard let newPlaces = try? await reads.places(in: read, origin: phone, limit: Self.placesPerRead),
              mine == pinGeneration else { return }
        places = newPlaces
        if let selected, newPlaces.contains(where: { $0.id == selected.id }) == false {
            self.selected = nil
            selectedMenu = []
        }
    }

    /// Search here: the sheet becomes every dish on screen.
    public func searchHere() async {
        guard let box else { return }
        analytics(MapEvents.searchedHere())
        await list(.area(box))
    }

    /// The location button: the phone again, and the sheet back on Near me. Returns the fix, for the
    /// view to glide the camera to. The view glides first (``locateAgain()``, then ``listNearMe(_:)``),
    /// so the camera never waits on a read.
    public func backToNearMe() async -> SearchOrigin? {
        guard let fix = await locateAgain() else { return nil }
        await listNearMe(fix)
        return fix
    }

    /// A fresh fix for the location button. `nil` without the permission.
    public func locateAgain() async -> SearchOrigin? {
        guard let fix = await locate(true) else { return nil }
        analytics(MapEvents.recentred())
        return fix
    }

    /// The sheet back on Near me around `fix`. The same spot (GPS wanders a few metres between fixes)
    /// keeps the list it has, or gets back the Near me it last read, instantly: no rows blanking to
    /// placeholders and filling again (build 216).
    public func listNearMe(_ fix: SearchOrigin) async {
        if case .some(.nearMe(let listed)) = listing, Self.isSameSpot(listed, fix) { return }
        if let kept = lastNearMe, Self.isSameSpot(kept.phone, fix) {
            phone = kept.phone
            listGeneration += 1
            isListing = false
            listing = .nearMe(kept.phone)
            title = .nearMe
            dishes = kept.dishes
            nextCursor = kept.next
            hasMoreDishes = kept.next != nil
            phase = .ready
            return
        }
        phone = fix
        await list(.nearMe(fix))
    }

    /// Two fixes this close are the same Near me.
    public nonisolated static let sameSpotMeters: Double = 100

    public nonisolated static func isSameSpot(_ a: SearchOrigin, _ b: SearchOrigin) -> Bool {
        let down = (a.latitude - b.latitude) * 111_320
        let across = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (down * down + across * across).squareRoot() <= sameSpotMeters
    }

    /// The next page of the sheet, when the list reaches its end.
    public func loadMoreDishes() async {
        guard let listing, let cursor = nextCursor, isLoadingMore == false else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let mine = listGeneration
        guard let fill = try? await fill(listing, after: cursor), mine == listGeneration else { return }
        let seen = Set(dishes.map(\.id))
        dishes += fill.items.filter { seen.contains($0.id) == false }
        nextCursor = fill.next
        hasMoreDishes = fill.next != nil
    }

    /// Another go after a failed read.
    public func retry() async {
        if let listing {
            await list(listing)
        } else {
            frame = nil
            await open()
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

    // MARK: - The list

    private func list(_ listing: Listing) async {
        self.listing = listing
        listGeneration += 1
        let mine = listGeneration
        isListing = true
        // A list on show (or its empty state) stays until the new one lands, title and all: Search here
        // and the location button never blank the sheet to placeholders and "This area" (Eamon, 27 Oct).
        if phase != .ready {
            title = Self.title(listing, area: nil)
            phase = isOnline ? .opening : .offline
            dishes = []
        }
        hasMoreDishes = false
        nextCursor = nil
        let stall = stallSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(stall))
            guard let self, mine == self.listGeneration, self.isListing, self.phase != .offline else { return }
            self.phase = .offline
        }
        do {
            let lookup = nameArea
            async let named = Self.name(listing, with: lookup)
            let fill = try await fill(listing, after: nil)
            let area = await named
            guard mine == listGeneration else { return }
            isListing = false
            title = Self.title(listing, area: area)
            dishes = fill.items
            nextCursor = fill.next
            hasMoreDishes = fill.next != nil
            phase = .ready
            if case .nearMe(let fix) = listing {
                lastNearMe = KeptNearMe(phone: fix, dishes: fill.items, next: fill.next)
            }
        } catch {
            guard mine == listGeneration else { return }
            isListing = false
            title = Self.title(listing, area: nil)
            phase = Self.isConnectionLost(error) || isOnline == false ? .offline : .failed
        }
    }

    private static func title(_ listing: Listing, area: String?) -> DishMapTitle {
        listing.area == nil ? .nearMe : .area(area)
    }

    private nonisolated static func name(_ listing: Listing, with lookup: NameArea) async -> String? {
        guard let box = listing.area, let name = await lookup(box), name.isEmpty == false else { return nil }
        return name
    }

    /// The phone's connection changed. Gone: a list still loading says No connection. Back: a list
    /// that said No connection (or failed) is read again, and so are the pins.
    public func connectionChanged(isOnline: Bool) async {
        let wasOnline = self.isOnline
        self.isOnline = isOnline
        guard isOnline else {
            if phase == .opening || isListing { phase = .offline }
            return
        }
        guard wasOnline == false || phase == .offline else { return }
        if let lastShown { Task { await self.show(lastShown.box, reading: lastShown.reading) } }
        if phase == .offline || phase == .failed { await retry() }
    }

    static func isConnectionLost(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        let lost: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff
        ]
        return lost.contains(error.code)
    }

    /// One page of the list. Near me reads the box round the radius and keeps the rows inside it,
    /// reading on (a few pages at most) while a page keeps nothing.
    private func fill(_ listing: Listing, after cursor: MapDishCursor?) async throws
        -> (items: [MapDish], next: MapDishCursor?) {
        var cursor = cursor
        for _ in 0..<Self.pagesPerFill {
            let page = try await reads.dishes(
                in: listing.box, origin: phone, after: cursor, pageSize: Self.dishesPerPage
            )
            let kept = page.items.filter { Self.isListed($0, in: listing) }
            cursor = page.nextCursor
            if kept.isEmpty == false || cursor == nil { return (kept, cursor) }
        }
        return ([], cursor)
    }

    static func isListed(_ dish: MapDish, in listing: Listing) -> Bool {
        guard case .nearMe = listing else { return true }
        guard let meters = dish.distanceMeters else { return false }
        return Double(meters) <= nearRadius
    }
}

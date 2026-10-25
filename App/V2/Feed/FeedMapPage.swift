import AteKit
import MapKit
import SwiftUI

/// **The dish map** (`nearby-map.html` option A, round 2 `nearby-map-2.html`) — pushed from the
/// Feed's map button.
///
/// Apple's map, full screen, opening on 10 km around you. A place is a pin, its best dish's photo with
/// the score as its one badge and one more photo stacked behind when it has more dishes, or a dot:
/// far out every place is a dot, and closer in the best-rated that fit keep their photos and the rest
/// are dots (``DishMapLayout``). A dot holding several places zooms in when tapped.
///
/// The sheet lies over the bottom (``FeedMapSheet``) and is part of the page, not a presented sheet:
/// it goes with the page on Back, never lingers over the Feed, and never stands between the map and
/// your finger. It lists Near me and holds still while you pan; Search here lists what is on screen.
/// It reads only what is on screen, once the map stops moving (0088).
struct FeedMapPage: View {
    let context: V2PageContext

    @State private var store: DishMapStore
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// What the map draws, laid out where the map last came to rest.
    @State private var marks: [FeedMapMark] = []
    @State private var region: MKCoordinateRegion?
    @State private var detent = FeedMapDetent.low
    @State private var areaLookup: Task<Void, Never>?

    init(context: V2PageContext) {
        self.context = context
        _store = State(initialValue: DishMapStore(
            reads: context.services.dishMap,
            menus: context.services.placePages,
            locate: context.services.locate,
            analytics: context.services.analytics
        ))
    }

    var body: some View {
        GeometryReader { page in
            ZStack(alignment: .bottom) {
                map
                    // The camera frames what is above the sheet's resting height.
                    .safeAreaPadding(.bottom, FeedMapMetrics.lowHeight)
                    .ignoresSafeArea()
                FeedMapSheet(
                    store: store,
                    detent: $detent,
                    room: FeedMapRoom(page: page),
                    onDish: { context.open(.dish($0), from: .map) },
                    onPlace: { context.open(.place($0), from: .map) }
                )
            }
            .overlay(alignment: .top) {
                if store.canSearchHere, store.selected == nil {
                    FeedMapSearchHere(action: searchHere)
                        .padding(.top, AteMetrics.snug)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.canSearchHere)
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await backToNearMe() } } label: {
                    AteIcon.navigation.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel(FeedMapCopy.recentre)
                .accessibilityIdentifier("map.recentre")
            }
        }
        .task { await store.open() }
        .onChange(of: store.frame) { _, frame in
            if let frame { position = .region(MKCoordinateRegion(frame)) }
        }
        // An area list is titled with its suburb.
        .task(id: store.listing) {
            guard case .some(.area(let box)) = store.listing else { return }
            let name = await Self.suburb(latitude: box.centerLatitude, longitude: box.centerLongitude)
            store.name(area: name, for: box)
        }
        .accessibilityIdentifier("map.page")
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                ForEach(marks) { mark in
                    Annotation(mark.label, coordinate: mark.coordinate, anchor: .center) {
                        marker(mark)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { camera in
                region = camera.region
                relayout(proxy)
                Task { await store.show(MapBox(camera.region)) }
            }
            .onChange(of: store.places) { relayout(proxy) }
            .onChange(of: store.selected) { relayout(proxy) }
        }
    }

    @ViewBuilder
    private func marker(_ mark: FeedMapMark) -> some View {
        switch mark.kind {
        case .photo(let place):
            let isSelected = store.selected?.id == place.id
            Button {
                Task { await select(place) }
            } label: {
                AteMapPin(
                    front: .dish(place.topDishID, name: place.topDishName, cover: place.topCoverURLString),
                    behind: place.secondCoverURLString.map(AtePhoto.remote),
                    score: place.topScore,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FeedMapCopy.pinLabel(place))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .dot(let members):
            Button {
                Task { await tapDot(members) }
            } label: {
                AteMapDot(isScored: members.contains { $0.topScore != nil }, count: members.count)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FeedMapCopy.dotLabel(members))
        }
    }

    /// What the map draws, projected where it is now: photos while they fit, dots for the rest.
    private func relayout(_ proxy: MapProxy) {
        let width = region.map { MapBox($0).widthMeters } ?? 0
        var located: [UUID: MapPlace] = [:]
        let candidates = store.places.compactMap { place -> DishMapLayout.Candidate? in
            guard let point = proxy.convert(place.coordinate, to: .local) else { return nil }
            located[place.id] = place
            return DishMapLayout.Candidate(
                id: place.id, across: point.x, down: point.y, score: place.topScore, dishCount: place.dishCount
            )
        }
        let arrangement = DishMapLayout.arrange(candidates, selected: store.selected?.id, widthMeters: width)
        let photos = store.places.filter { arrangement.photos.contains($0.id) }.map(FeedMapMark.photo)
        let dots = arrangement.dots.map { dot in FeedMapMark.dot(dot.members.compactMap { located[$0] }) }
        marks = photos + dots.compactMap { $0 }
    }

    private func select(_ place: MapPlace) async {
        if detent == .minimised { withAnimation(AteMotion.panelSettle) { detent = .low } }
        await store.select(place)
    }

    /// One place grows into its photos; several zoom the map in on them, and they split apart.
    private func tapDot(_ members: [MapPlace]) async {
        guard members.count > 1 else {
            if let only = members.first { await select(only) }
            return
        }
        guard let box = MapBox.fitting(members.map(\.origin), padding: 0.4, minimumSpan: FeedMapMetrics.dotZoomSpan)
        else { return }
        withAnimation(AteMotion.mapGlide) { position = .region(MKCoordinateRegion(box)) }
    }

    private func searchHere() {
        if detent == .minimised { withAnimation(AteMotion.panelSettle) { detent = .low } }
        Task { await store.searchHere() }
    }

    /// Show my location: glide to the phone at the opening view's 10 km, the sheet back on Near me.
    private func backToNearMe() async {
        guard let fix = await store.backToNearMe() else { return }
        let box = MapBox.around(fix, radiusMeters: DishMapStore.nearRadius)
        withAnimation(AteMotion.mapGlide) { position = .region(MKCoordinateRegion(box)) }
    }

    /// The suburb in the middle of an area, for its title ("Carlton").
    private nonisolated static func suburb(latitude: Double, longitude: Double) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
        else { return nil }
        return try? await request.mapItems.first?.addressRepresentations?.cityName
    }
}

/// One thing the map draws: a place as a photo pin, or a dot holding one place or several.
struct FeedMapMark: Identifiable {
    enum Kind {
        case photo(MapPlace)
        case dot([MapPlace])
    }

    let id: String
    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let label: String

    static func photo(_ place: MapPlace) -> FeedMapMark {
        FeedMapMark(id: "photo-\(place.id)", kind: .photo(place), coordinate: place.coordinate, label: place.name)
    }

    /// A dot sits at the middle of its places. `nil` for no places.
    static func dot(_ members: [MapPlace]) -> FeedMapMark? {
        guard let first = members.first else { return nil }
        let count = Double(members.count)
        let coordinate = CLLocationCoordinate2D(
            latitude: members.map(\.latitude).reduce(0, +) / count,
            longitude: members.map(\.longitude).reduce(0, +) / count
        )
        return FeedMapMark(id: "dot-\(first.id)", kind: .dot(members), coordinate: coordinate, label: first.name)
    }
}

/// **Search here** (`nearby-map-2.html`): a glass capsule at the top of the map once it has moved
/// off what the sheet lists.
struct FeedMapSearchHere: View {
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.tight) {
                AteIcon.search.view(size: FeedMapMetrics.searchGlyph)
                Text(FeedMapCopy.searchHere).ateText(.control)
            }
            .foregroundStyle(palette.fg)
            .padding(.horizontal, AteMetrics.loose)
            .frame(height: AteMetrics.hit)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("map.searchHere")
    }
}

enum FeedMapMetrics {
    /// The sheet's resting height: the title and two and a half rows (`nearby-map.html` `.sheet`).
    static let lowHeight: CGFloat = 320
    /// A tapped dot zooms to at least this span (degrees, a few blocks), so its places split apart.
    static let dotZoomSpan: Double = 0.004
    static let searchGlyph: CGFloat = 17
}

enum FeedMapCopy {
    static let open = "Map"
    static let recentre = "Show my location"
    static let searchHere = "Search here"
    static let openPlace = "Open place"
    static let close = "Close"
    static let unreachable = "The map couldn't load"
    static let tryAgain = "Try again"

    static func pinLabel(_ place: MapPlace) -> String {
        let score = place.topScore.map { ", \(ScoreFormat.average($0))" } ?? ""
        return "\(place.name): \(place.topDishName)\(score)"
    }

    /// A dot: its place, or how many places it holds.
    static func dotLabel(_ members: [MapPlace]) -> String {
        guard members.count > 1 else { return members.first.map(pinLabel) ?? "" }
        return "\(members.count) places"
    }

    /// Under a tapped place's dish: how many people ate it.
    static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }

    /// Under a dish or a place: where, and how far — "Small Wins · 350 m".
    static func whereAndHowFar(_ name: String, meters: Int?) -> String {
        guard let meters else { return name }
        return "\(name) · \(MapDistance.text(meters: meters))"
    }
}

extension MapPlace {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension MapBox {
    init(_ region: MKCoordinateRegion) {
        self.init(
            centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta
        )
    }
}

extension MKCoordinateRegion {
    init(_ box: MapBox) {
        self.init(
            center: CLLocationCoordinate2D(latitude: box.centerLatitude, longitude: box.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: box.latitudeDelta, longitudeDelta: box.longitudeDelta)
        )
    }
}

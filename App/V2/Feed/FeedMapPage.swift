import AteKit
import MapKit
import SwiftUI

/// **The dish map** (`nearby-map.html`, option A, approved 25 Oct) — pushed from the Feed's map button.
///
/// Apple's map, full screen, with a pin per place that has dishes: its best dish's photo with the
/// score as its one badge, and one more photo stacked behind when it has more dishes. Where places
/// crowd, the best-rated that fit without touching keep their photos and the rest are dots
/// (``DishMapLayout``); zooming in turns dots into photos. A native sheet lies over the bottom:
/// "Dishes near you", best first, or a tapped place's own dishes.
///
/// It opens framed on you and the nearest places with dishes, however far, so it is never empty.
/// It reads only what is on screen, once the map stops moving (0088).
struct FeedMapPage: View {
    let context: V2PageContext

    @State private var store: DishMapStore
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The places drawn as photos; every other place is a dot.
    @State private var photoIDs: Set<UUID> = []
    @State private var region: MKCoordinateRegion?
    @State private var isSheetUp = false
    @State private var detent = FeedMapMetrics.lowDetent
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
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                ForEach(store.places) { place in
                    Annotation(place.name, coordinate: place.coordinate, anchor: .center) {
                        marker(place)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { camera in
                region = camera.region
                relayout(proxy)
                lookUpArea(camera.region.center)
                Task { await store.show(MapBox(camera.region)) }
            }
            .onChange(of: store.places) { relayout(proxy) }
            .onChange(of: store.selected) { relayout(proxy) }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await recentre() } } label: {
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
        // The sheet goes with the page: down for a pushed page, back up on the way back.
        .onAppear { isSheetUp = true }
        .onDisappear { isSheetUp = false }
        .sheet(isPresented: $isSheetUp) {
            FeedMapSheet(store: store, onDish: { open(.dish($0)) }, onPlace: { open(.place($0)) })
                .presentationDetents([FeedMapMetrics.lowDetent, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .accessibilityIdentifier("map.page")
    }

    @ViewBuilder
    private func marker(_ place: MapPlace) -> some View {
        let isSelected = store.selected?.id == place.id
        Button {
            Task { await store.select(place) }
        } label: {
            if photoIDs.contains(place.id) || isSelected {
                AteMapPin(
                    front: .dish(place.topDishID, name: place.topDishName, cover: place.topCoverURLString),
                    behind: place.secondCoverURLString.map(AtePhoto.remote),
                    score: place.topScore,
                    isSelected: isSelected
                )
            } else {
                AteMapDot(isScored: place.topScore != nil)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FeedMapCopy.pinLabel(place))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Which places are photos: projected where the map draws them now, best first while they fit.
    private func relayout(_ proxy: MapProxy) {
        let candidates = store.places.compactMap { place -> DishMapLayout.Candidate? in
            guard let point = proxy.convert(place.coordinate, to: .local) else { return nil }
            return DishMapLayout.Candidate(
                id: place.id, across: point.x, down: point.y, score: place.topScore, dishCount: place.dishCount
            )
        }
        photoIDs = DishMapLayout.photoPins(candidates, selected: store.selected?.id)
    }

    /// The suburb in the middle of the map, for "Dishes in Carlton" once the map is off you. One
    /// lookup per resting place, the last one winning.
    private func lookUpArea(_ centre: CLLocationCoordinate2D) {
        areaLookup?.cancel()
        areaLookup = Task {
            let area = await Self.suburb(latitude: centre.latitude, longitude: centre.longitude)
            guard Task.isCancelled == false else { return }
            store.area = area
        }
    }

    private nonisolated static func suburb(latitude: Double, longitude: Double) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
        else { return nil }
        return try? await request.mapItems.first?.addressRepresentations?.cityName
    }

    private func recentre() async {
        guard let fix = await store.recentre() else { return }
        let span = region?.span ?? MKCoordinateSpan(
            latitudeDelta: FeedMapMetrics.recentreSpan, longitudeDelta: FeedMapMetrics.recentreSpan
        )
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude), span: span
        ))
    }

    private func open(_ route: Route) {
        isSheetUp = false
        context.open(route, from: .map)
    }
}

enum FeedMapMetrics {
    /// The sheet's resting height: the title and two and a half rows (`nearby-map.html` `.sheet`).
    static var lowDetent: PresentationDetent { .height(300) }
    /// Show my location before the map has a span of its own: a few blocks.
    static let recentreSpan: CLLocationDegrees = 0.02
}

enum FeedMapCopy {
    static let open = "Map"
    static let recentre = "Show my location"
    static let openPlace = "Open place"
    static let close = "Close"
    static let empty = "No dishes in view"
    static let unreachable = "The map couldn't load"
    static let tryAgain = "Try again"

    static func pinLabel(_ place: MapPlace) -> String {
        let score = place.topScore.map { ", \(ScoreFormat.average($0))" } ?? ""
        return "\(place.name): \(place.topDishName)\(score)"
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

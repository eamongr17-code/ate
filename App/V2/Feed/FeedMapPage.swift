import AteKit
import MapKit
import SwiftUI

/// **The dish map** (`nearby-map.html` option A, round 2 `nearby-map-2.html`) — pushed from the
/// Feed's map button.
///
/// Apple's map, full screen, opening on 2 km around you. A place is a pin, its best dish's photo with
/// the score as its one badge and one more photo stacked behind when it has more dishes, or a dot:
/// far out every place is a dot, and closer in the best-rated that fit keep their photos and the rest
/// are dots (``DishMapLayout``). A dot holding several places zooms in when tapped.
///
/// The sheet lies over the bottom (``FeedMapSheet``) and is part of the page, not a presented sheet:
/// it goes with the page on Back, never lingers over the Feed, and never stands between the map and
/// your finger. It lists Near me and holds still while you pan; Search here lists what is on screen.
/// It reads once the map stops moving (0088), half a screen past each edge, so a place panned back
/// into view is already there.
///
/// The map never changes size or insets as the sheet moves (build 216: it was laid out above the
/// sheet, so every drag resized it, the camera re-fitted mid-animation and the page showed through
/// behind the glass). The sheet slides over a still map; the camera frames its views clear of the
/// resting sheet itself (``FeedMapFraming``).
struct FeedMapPage: View {
    let context: V2PageContext

    @State private var store: DishMapStore
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// What the map draws, laid out where the map last came to rest.
    @State private var marks: [FeedMapMark] = []
    @State private var region: MKCoordinateRegion?
    @State private var detent = FeedMapDetent.low
    @State private var framing: FeedMapFraming?
    @State private var showsSearchHere = false

    init(context: V2PageContext) {
        self.context = context
        _store = State(initialValue: DishMapStore(
            reads: context.services.dishMap,
            menus: context.services.placePages,
            locate: context.services.locate,
            nameArea: { box in await FeedMapPage.suburb(latitude: box.centerLatitude, longitude: box.centerLongitude) },
            analytics: context.services.analytics
        ))
    }

    var body: some View {
        GeometryReader { page in
            let room = FeedMapRoom(page: page)
            ZStack(alignment: .bottom) {
                map
                    // The Apple Maps mark and Legal sit just over the minimised sheet (build 215: it
                    // floated mid-screen), and the sheet covers them when it rises, as when tall.
                    // Fixed: never animated with the sheet (build 216).
                    .safeAreaPadding(.bottom, FeedMapFraming(room: room).minimisedBottom)
                    .ignoresSafeArea()
                FeedMapSheet(
                    store: store,
                    detent: $detent,
                    room: room,
                    onDish: { context.open(.dish($0), from: .map) },
                    onPlace: { context.open(.place($0), from: .map) }
                )
                // Measured from the screen's bottom edge, not the safe area's (build 215).
                .ignoresSafeArea()
            }
            .onChange(of: FeedMapFraming(room: room), initial: true) { _, measured in framing = measured }
            // The whole screen: the map under the bars, the sheet down to the screen's edge.
            .frame(width: AteScreen.width, height: room.screen)
            .ignoresSafeArea()
        }
        .feedMapBar(
            showsSearchHere: showsSearchHere && store.selected == nil,
            searchHere: searchHere,
            recentre: { Task { await backToNearMe() } }
        )
        .task { await store.open() }
        // No connection on the sheet, and the sheet and pins read again when it comes back.
        .task {
            for await isOnline in ConnectivityWatch.states() { await store.connectionChanged(isOnline: isOnline) }
        }
        .onChange(of: store.frame) { _, frame in
            guard let frame else { return }
            let target = framing?.region(frame, detent: detent) ?? MKCoordinateRegion(frame)
            position = .region(target)
            // What the map shows once there, without waiting for MapKit to say so: a camera end from
            // the map's first, unframed view could land after this, or none come for the framing,
            // and Search here was up on opening (the nightly drive, 27 Oct).
            Task { await store.show(shown(target), reading: MapBox(target).grown(by: FeedMapMetrics.readAhead)) }
        }
        // The bar's items take no implicit animation; Search here fades in and out by hand.
        .onChange(of: store.canSearchHere) { _, can in
            withAnimation(AteMotion.fillIn) { showsSearchHere = can }
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
                let reading = MapBox(camera.region).grown(by: FeedMapMetrics.readAhead)
                Task { await store.show(shown(camera.region), reading: reading) }
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
            .modifier(FeedMapPinEntrance())
        case .dot(let members):
            Button {
                Task { await tapDot(members) }
            } label: {
                AteMapDot(isScored: members.contains { $0.topScore != nil }, count: members.count)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FeedMapCopy.dotLabel(members))
            .modifier(FeedMapPinEntrance())
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
        let arrangement = DishMapLayout.arrange(
            candidates, selected: store.selected?.id, widthMeters: width,
            screenWidth: AteScreen.width, screenHeight: AteScreen.height
        )
        let photos = store.places.filter { arrangement.photos.contains($0.id) }.map(FeedMapMark.photo)
        let dots = arrangement.dots.map { dot in FeedMapMark.dot(dot.members.compactMap { located[$0] }) }
        marks = photos + dots.compactMap { $0 }
    }

    /// What is on screen and not under the sheet at rest, with the camera on `region`: what Search
    /// here lists, and what it measures the map's moves against.
    private func shown(_ region: MKCoordinateRegion) -> MapBox {
        framing?.visible(region, detent: detent) ?? MapBox(region)
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
        glide(to: box)
    }

    private func glide(to box: MapBox) {
        let target = framing?.region(box, detent: detent) ?? MKCoordinateRegion(box)
        withAnimation(AteMotion.mapGlide) { position = .region(target) }
    }

    private func searchHere() {
        if detent == .minimised { withAnimation(AteMotion.panelSettle) { detent = .low } }
        Task { await store.searchHere() }
    }

    /// Show my location: glide to the phone at the opening view's 2 km, the sheet back on Near me.
    /// The glide starts on the tap, from the last fix, before any read: build 216 waited for the fix
    /// and the whole list first, then set the camera in the same update as the rows landing, and the
    /// map took the jump without the glide. A fresh fix far from the last one glides on to it.
    private func backToNearMe() async {
        let last = store.phone
        if let last { glide(to: MapBox.around(last, radiusMeters: DishMapStore.nearRadius)) }
        guard let fix = await store.locateAgain() else { return }
        if last.map({ DishMapStore.isSameSpot($0, fix) }) != true {
            glide(to: MapBox.around(fix, radiusMeters: DishMapStore.nearRadius))
        }
        await store.listNearMe(fix)
    }

    /// The suburb in the middle of an area, for its title ("Carlton"). The store looks it up with the
    /// list, so the title changes with the rows.
    private nonisolated static func suburb(latitude: Double, longitude: Double) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
        else { return nil }
        return try? await request.mapItems.first?.addressRepresentations?.cityName
    }
}

/// **Where the camera puts a view**: the map's insets never move (the sheet slides over it), so a
/// box is framed into what the resting sheet leaves clear: centred there and fitting there, the way
/// the map's own safe area used to frame it.
struct FeedMapFraming: Equatable {
    /// Down from the screen's top to the top bar's bottom.
    let top: CGFloat
    let screen: CGFloat
    let width: CGFloat
    /// The minimised sheet's top, up from the screen's bottom: the map's bottom inset.
    let minimisedBottom: CGFloat
    /// The resting sheet's top, up from the screen's bottom.
    let lowBottom: CGFloat

    @MainActor
    init(room: FeedMapRoom) {
        top = room.topInset
        screen = room.screen
        width = AteScreen.width
        minimisedBottom = room.height(.minimised, head: FeedMapSheetMetrics.headEstimate) + FeedMapSheetMetrics.inset
        lowBottom = FeedMapMetrics.lowHeight + FeedMapSheetMetrics.inset
    }

    /// Down from the screen's top to the sheet's top as it rests (tall frames as resting does).
    func clearBottom(_ detent: FeedMapDetent) -> CGFloat {
        screen - (detent == .minimised ? minimisedBottom : lowBottom)
    }

    /// What MapKit frames a region in: the whole map down to its bottom inset, the minimised sheet's
    /// top. The map runs under the top bar with no top inset (measured: insets top 0, bottom 110 on
    /// a 402 × 874 screen), so a region's middle sits at this height's middle, not under the bar.
    var mapHeight: CGFloat { max(screen - minimisedBottom, 1) }

    /// The region that shows `box` whole and centred in what the sheet leaves clear.
    func region(_ box: MapBox, detent: FeedMapDetent) -> MKCoordinateRegion {
        let metersPerDegree = 111_320.0
        let shrink = max(cos(box.centerLatitude * .pi / 180), 0.01)
        let framed = Double(mapHeight)
        let clear = Double(max(clearBottom(detent) - top, 1))
        let across = Double(max(width, 1))
        let metersPerPoint = max(box.widthMeters / across, box.latitudeDelta * metersPerDegree / clear)
        // The clear part's middle sits this far above the framed part's middle.
        let lift = Double(mapHeight / 2 - (top + clearBottom(detent)) / 2)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: box.centerLatitude - lift * metersPerPoint / metersPerDegree,
                longitude: box.centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: framed * metersPerPoint / metersPerDegree,
                longitudeDelta: across * metersPerPoint / metersPerDegree / shrink
            )
        )
    }

    /// The part of `region` between the top bar and the resting sheet. Worked out from the region
    /// (MapKit reports it for ``mapHeight``), not by asking the map to convert points: that read the
    /// whole region when it failed, and the opening view counted as moved (the nightly drive, 27 Oct).
    func visible(_ region: MKCoordinateRegion, detent: FeedMapDetent) -> MapBox {
        let perPoint = region.span.latitudeDelta / Double(mapHeight)
        let middle = Double(mapHeight / 2)
        return MapBox(
            minLatitude: region.center.latitude - (Double(clearBottom(detent)) - middle) * perPoint,
            minLongitude: region.center.longitude - region.span.longitudeDelta / 2,
            maxLatitude: region.center.latitude + (middle - Double(top)) * perPoint,
            maxLongitude: region.center.longitude + region.span.longitudeDelta / 2
        )
    }
}

/// A pin or a dot coming into view (built, or panned back on screen) grows in from a little smaller,
/// fading up, rather than flashing on (build 216). With Reduce Motion it is simply there.
private struct FeedMapPinEntrance: ViewModifier {
    @State private var isIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isIn || reduceMotion ? 1 : AteMotion.pinInScale)
            .opacity(isIn || reduceMotion ? 1 : 0)
            .onAppear {
                guard isIn == false else { return }
                withAnimation(AteMotion.pinIn) { isIn = true }
            }
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

extension View {
    /// The map's top bar: Back, Search here in the row's middle, Show my location trailing. In the bar
    /// itself: drawn in the page under the bar, the bar took its taps (build 216, it did nothing).
    ///
    /// Never `.toolbar(removing: .title)` here: the middle of the bar *is* the title's slot, and with
    /// the title removed the bar kept Search here but hid it and passed its taps by (builds 217–243:
    /// "the Search here button is gone"; `DishMapBarTests`). The page sets no title, so none shows.
    func feedMapBar(showsSearchHere: Bool, searchHere: @escaping () -> Void, recentre: @escaping () -> Void)
        -> some View {
        toolbarVisibility(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsSearchHere {
                    ToolbarItem(placement: .principal) {
                        FeedMapSearchHere(action: searchHere)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: recentre) {
                        AteIcon.navigation.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel(FeedMapCopy.recentre)
                    .accessibilityIdentifier("map.recentre")
                }
            }
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
    /// Pins are read this much of the screen past each edge.
    static let readAhead: Double = 0.5
    static let searchGlyph: CGFloat = 17
}

enum FeedMapCopy {
    static let open = "Map"
    static let recentre = "Show my location"
    static let searchHere = "Search here"
    static let openPlace = "Open place"
    static let close = "Close"
    static let unreachable = "Couldn't\nload the map."
    static let noConnection = "No connection."
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

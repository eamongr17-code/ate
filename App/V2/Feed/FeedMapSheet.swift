import AteKit
import SwiftUI

/// **The sheet over the dish map** (`nearby-map-2.html`): **Near me** — every dish within 2 km, best
/// first, paged as you scroll — or the suburb after Search here, or, with a pin tapped, that place:
/// its name, where it is, Open place, and its dishes best first. The title says the place only.
///
/// Drawn in the page, not presented: a presented sheet over a pushed page stayed on screen after Back
/// and raced the pushes it made, the map's lost touches in build 214. It floats on glass like the
/// system's, and drags between three heights: minimised to its title, resting, and tall. Below the
/// tallest the whole sheet drags; at the tallest the list scrolls and the top drags.
struct FeedMapSheet: View {
    let store: DishMapStore
    @Binding var detent: FeedMapDetent
    let room: FeedMapRoom
    let onDish: (UUID) -> Void
    let onPlace: (UUID) -> Void

    @Environment(\.atePalette) private var palette
    /// How far the finger has pulled the sheet up (down is negative) since the drag began. State, not
    /// gesture state, so it settles back to 0 in the same animation as the new height.
    @State private var pull: CGFloat = 0
    /// The grabber and the title, measured: minimised, the sheet is exactly this over the home bar.
    @State private var headHeight = FeedMapSheetMetrics.headEstimate

    var body: some View {
        let isTall = detent == .high
        VStack(alignment: .leading, spacing: 0) {
            head
                .contentShape(.rect)
                .gesture(drag)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    // Minimised, the sheet is the head: it grows and shrinks with it, never jumps.
                    withAnimation(detent == .minimised ? AteMotion.panelSettle : nil) { headHeight = measured }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    list
                }
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, room.bottomInset + AteMetrics.section)
            }
            .scrollIndicators(.hidden)
            // Minimised is the title alone: no row peeking under it (build 215). It comes back as
            // soon as the sheet is pulled up.
            .opacity(detent == .minimised && pull <= 0 ? 0 : 1)
            .scrollDisabled(isTall == false)
            .gesture(drag, including: isTall ? .subviews : .all)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .clipShape(.rect(cornerRadius: FeedMapSheetMetrics.radius))
        .glassEffect(.regular, in: .rect(cornerRadius: FeedMapSheetMetrics.radius))
        .padding(.horizontal, FeedMapSheetMetrics.inset)
        .padding(.bottom, FeedMapSheetMetrics.inset)
        .ateAnimation(AteMotion.fillIn, value: store.selected?.id)
        .ateAnimation(AteMotion.fillIn, value: store.selectedMenu.map(\.dishID))
        .accessibilityIdentifier("map.sheet")
    }

    // MARK: - Height

    private var height: CGFloat {
        let resting = height(detent)
        return min(max(resting + pull, height(.minimised)), height(.high))
    }

    private func height(_ detent: FeedMapDetent) -> CGFloat {
        room.height(detent, head: headHeight)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: FeedMapSheetMetrics.dragStart, coordinateSpace: .global)
            .onChanged { value in pull = -value.translation.height }
            .onEnded { value in
                let landing = height(detent) - value.predictedEndTranslation.height
                let nearest = FeedMapDetent.allCases.min {
                    abs(height($0) - landing) < abs(height($1) - landing)
                }
                withAnimation(AteMotion.panelSettle) {
                    detent = nearest ?? detent
                    pull = 0
                }
            }
    }

    // MARK: - The top: the grabber and the title (or the tapped place)

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(palette.muted.opacity(FeedMapSheetMetrics.grabberOpacity))
                .frame(width: FeedMapSheetMetrics.grabberWidth, height: FeedMapSheetMetrics.grabberHeight)
                .frame(maxWidth: .infinity)
                .padding(.top, FeedMapSheetMetrics.grabberTop)
                .accessibilityHidden(true)
            Group {
                if let place = store.selected {
                    placeHead(place)
                        .transition(FeedMapSheetMotion.swap)
                } else {
                    Text(store.title.text)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("map.title")
                        .transition(FeedMapSheetMotion.swap)
                }
            }
            .padding(.top, FeedMapSheetMetrics.titleTop)
            .padding(.bottom, FeedMapSheetMetrics.titleGap)
            .padding(.horizontal, AteMetrics.gutter)
        }
    }

    // MARK: - The list

    /// Near me (or Search here), or the tapped place's dishes: one list, its rows known by their
    /// dish, so a dish in both stays put when a pin is tapped or let go, and only what differs comes
    /// and goes (build 217: the two lists cross-faded through each other, and so did the titles).
    @ViewBuilder
    private var list: some View {
        if let shown {
            rows(shown)
        } else {
            nearbyState
        }
    }

    /// The rows on show, or `nil` while Near me has none to show (loading, failed or empty).
    private var shown: [FeedMapSheetRow]? {
        if let place = store.selected { return placeRows(place) }
        guard store.phase == .ready, store.dishes.isEmpty == false else { return nil }
        return nearbyRows
    }

    private func rows(_ rows: [FeedMapSheetRow]) -> some View {
        let letters = DishLetter.neighbourly(rows.map { ($0.id, $0.name) })
        return ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            AteDishRow(
                photo: .dish(letters[index], cover: row.cover),
                name: row.name,
                tags: row.tags,
                subtitle: row.subtitle,
                score: row.score.map(AteScore.average),
                isFirst: index == 0,
                onOpen: { onDish(row.id) }
            )
            .onAppear {
                if store.selected == nil, index == rows.count - 1 { Task { await store.loadMoreDishes() } }
            }
            .transition(FeedMapSheetMotion.swap)
        }
    }

    /// The place's menu, or until it is read, its dishes already in the list (no empty sheet).
    private func placeRows(_ place: MapPlace) -> [FeedMapSheetRow] {
        guard store.selectedMenu.isEmpty else {
            return store.selectedMenu.map { dish in
                FeedMapSheetRow(
                    id: dish.dishID, name: dish.name, cover: dish.coverURLString, tags: dish.tags,
                    subtitle: FeedMapCopy.people(dish.peopleCount), score: dish.score
                )
            }
        }
        let theirs = Set(store.dishes.filter { $0.restaurantID == place.restaurantID }.map(\.dishID))
        return nearbyRows.filter { theirs.contains($0.id) }
    }

    private var nearbyRows: [FeedMapSheetRow] {
        store.dishes.map { dish in
            FeedMapSheetRow(
                id: dish.dishID, name: dish.name, cover: dish.coverURLString, tags: [],
                subtitle: FeedMapCopy.whereAndHowFar(dish.placeName, meters: dish.distanceMeters),
                score: dish.score
            )
        }
    }

    @ViewBuilder
    private var nearbyState: some View {
        switch store.phase {
        case .opening:
            ForEach(0..<FeedMapSheetMetrics.skeletonRows, id: \.self) { _ in
                AteDishRow(photo: AtePhoto(), name: " ").redacted(reason: .placeholder)
            }
        case .failed:
            AteEmptyState(line: FeedMapCopy.unreachable, art: .torn, pill: (FeedMapCopy.tryAgain, retry))
                .accessibilityIdentifier("map.unreachable")
        case .offline:
            AteEmptyState(line: FeedMapCopy.noConnection, art: .torn, pill: (FeedMapCopy.tryAgain, retry))
                .accessibilityIdentifier("map.offline")
        case .ready:
            Text(store.title.emptyLine)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .accessibilityIdentifier("map.empty")
        }
    }

    // MARK: - A tapped place

    private func placeHead(_ place: MapPlace) -> some View {
        VStack(alignment: .leading, spacing: FeedMapSheetMetrics.headGap) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: FeedMapSheetMetrics.lineGap) {
                    Text(place.name)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let line = placeLine(place) {
                        Text(line)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                    }
                }
                Spacer(minLength: AteMetrics.gutter)
                AteGlassDisc(icon: .close, label: FeedMapCopy.close, size: FeedMapSheetMetrics.close) {
                    Task { await store.select(nil) }
                }
            }
            AteInkPill(title: FeedMapCopy.openPlace, size: .row, identifier: "map.openPlace") {
                onPlace(place.restaurantID)
            }
            .fixedSize()
        }
    }

    private func placeLine(_ place: MapPlace) -> String? {
        let parts = [place.locality, place.distanceMeters.map(MapDistance.text(meters:))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func retry() {
        Task { await store.retry() }
    }
}

/// One dish in the sheet's list, from Near me or from a tapped place's menu.
struct FeedMapSheetRow: Identifiable {
    let id: UUID
    let name: String
    let cover: String?
    let tags: [DietTag]
    let subtitle: String
    let score: Double?
}

enum FeedMapSheetMotion {
    /// What changes when a pin is tapped or let go fades in, and what goes leaves at once, so the
    /// old and the new never show through each other.
    static var swap: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }
}

/// The sheet's three heights.
enum FeedMapDetent: CaseIterable {
    /// Down to its title: the map nearly full screen.
    case minimised
    /// Resting: the title and two and a half rows.
    case low
    /// Up under the map's top buttons.
    case high
}

/// The screen the sheet lies in: how tall it is, and what the system keeps at the top and bottom.
/// Everything is measured from the screen's own edges (the page draws under the bars).
struct FeedMapRoom {
    /// The whole screen's height, top bar and home indicator included.
    let screen: CGFloat
    /// The status bar and the top bar (Back, Show my location).
    let topInset: CGFloat
    /// The home indicator.
    let bottomInset: CGFloat
    /// Down from the screen's top to the middle of the top bar's row.
    let barMiddle: CGFloat

    /// The screen and the home indicator come from the window (``AteScreen``): inside a navigation
    /// stack a `GeometryReader`'s bottom inset is not the screen's, and build 215's sheet floated
    /// above it. The top bar's height only the page knows.
    @MainActor
    init(page: GeometryProxy) {
        let statusBar = AteScreen.safeArea.top
        screen = AteScreen.height
        bottomInset = AteScreen.safeArea.bottom
        topInset = max(page.safeAreaInsets.top, statusBar + AteMetrics.hit)
        barMiddle = (statusBar + topInset) / 2
    }

    /// From the sheet's bottom (``FeedMapSheetMetrics/inset`` above the screen's) to its top. `head` is
    /// the grabber and title's measured height: minimised shows that and nothing under it.
    func height(_ detent: FeedMapDetent, head: CGFloat) -> CGFloat {
        let inset = FeedMapSheetMetrics.inset
        switch detent {
        case .minimised: return head + max(bottomInset - inset, 0)
        case .low: return FeedMapMetrics.lowHeight
        case .high: return screen - topInset - 2 * inset
        }
    }
}

enum FeedMapSheetMetrics {
    /// The sheet floats this far in from the screen's sides and bottom, as the system's does.
    static let inset: CGFloat = 8
    static let radius: CGFloat = 38
    static let grabberTop: CGFloat = 6
    static let grabberWidth: CGFloat = 36
    static let grabberHeight: CGFloat = 5
    static let grabberOpacity: Double = 0.45
    /// Grabber to title: clear of the sheet's top (Eamon, build 214: the title sat too close to it).
    static let titleTop: CGFloat = 20
    static let titleGap: CGFloat = 12
    /// The grabber and the title, until measured.
    static let headEstimate: CGFloat = 76
    static let dragStart: CGFloat = 6
    static let headGap: CGFloat = 12
    static let lineGap: CGFloat = 4
    static let close: CGFloat = 34
    static let skeletonRows = 3
}

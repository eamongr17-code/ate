import AteKit
import SwiftUI

/// **The sheet over the dish map** (`nearby-map-2.html`): **Near me** — every dish within 10 km, best
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

    var body: some View {
        let isTall = detent == .high
        VStack(alignment: .leading, spacing: 0) {
            head
                .contentShape(.rect)
                .gesture(drag)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let place = store.selected {
                        placeDishes(place)
                    } else {
                        nearby
                    }
                }
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, room.bottomInset + AteMetrics.section)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(isTall == false)
            .gesture(drag, including: isTall ? .subviews : .all)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .clipShape(.rect(cornerRadius: FeedMapSheetMetrics.radius))
        .glassEffect(.regular, in: .rect(cornerRadius: FeedMapSheetMetrics.radius))
        .padding(.horizontal, FeedMapSheetMetrics.inset)
        .padding(.bottom, FeedMapSheetMetrics.inset)
        .ignoresSafeArea(edges: .bottom)
        .ateAnimation(AteMotion.fillIn, value: store.selected?.id)
        .accessibilityIdentifier("map.sheet")
    }

    // MARK: - Height

    private var height: CGFloat {
        let resting = room.height(detent)
        return min(max(resting + pull, room.height(.minimised)), room.height(.high))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: FeedMapSheetMetrics.dragStart, coordinateSpace: .global)
            .onChanged { value in pull = -value.translation.height }
            .onEnded { value in
                let landing = room.height(detent) - value.predictedEndTranslation.height
                let nearest = FeedMapDetent.allCases.min {
                    abs(room.height($0) - landing) < abs(room.height($1) - landing)
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
                } else {
                    Text(store.title.text)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("map.title")
                }
            }
            .padding(.top, FeedMapSheetMetrics.titleTop)
            .padding(.bottom, FeedMapSheetMetrics.titleGap)
            .padding(.horizontal, AteMetrics.gutter)
        }
    }

    // MARK: - Near me, or Search here

    @ViewBuilder
    private var nearby: some View {
        switch store.phase {
        case .opening:
            ForEach(0..<FeedMapSheetMetrics.skeletonRows, id: \.self) { _ in
                AteDishRow(photo: AtePhoto(), name: " ").redacted(reason: .placeholder)
            }
        case .failed:
            AteEmptyState(line: FeedMapCopy.unreachable, art: .torn, pill: (FeedMapCopy.tryAgain, retry))
                .accessibilityIdentifier("map.unreachable")
        case .ready:
            if store.dishes.isEmpty {
                Text(store.title.emptyLine)
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                    .accessibilityIdentifier("map.empty")
            } else {
                let letters = DishLetter.neighbourly(store.dishes.map { ($0.dishID, $0.name) })
                ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
                    AteDishRow(
                        photo: .dish(letters[index], cover: dish.coverURLString),
                        name: dish.name,
                        subtitle: FeedMapCopy.whereAndHowFar(dish.placeName, meters: dish.distanceMeters),
                        score: dish.score.map(AteScore.average),
                        isFirst: index == 0,
                        onOpen: { onDish(dish.dishID) }
                    )
                    .onAppear {
                        if index == store.dishes.count - 1 { Task { await store.loadMoreDishes() } }
                    }
                }
            }
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

    @ViewBuilder
    private func placeDishes(_ place: MapPlace) -> some View {
        let menu = store.selectedMenu
        let letters = DishLetter.neighbourly(menu.map { ($0.dishID, $0.name) })
        ForEach(Array(menu.enumerated()), id: \.element.id) { index, dish in
            AteDishRow(
                photo: .dish(letters[index], cover: dish.coverURLString),
                name: dish.name,
                tags: dish.tags,
                subtitle: FeedMapCopy.people(dish.peopleCount),
                score: dish.score.map(AteScore.average),
                isFirst: index == 0,
                onOpen: { onDish(dish.dishID) }
            )
        }
    }

    private func retry() {
        Task { await store.retry() }
    }
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

/// The page the sheet lies in: how tall it is, and what the system keeps at the top and bottom.
struct FeedMapRoom {
    /// The whole screen's height, top safe area and home indicator included.
    let screen: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(page: GeometryProxy) {
        topInset = page.safeAreaInsets.top
        bottomInset = page.safeAreaInsets.bottom
        screen = page.size.height + topInset + bottomInset
    }

    /// From the screen's bottom edge to the sheet's top.
    func height(_ detent: FeedMapDetent) -> CGFloat {
        switch detent {
        case .minimised: FeedMapSheetMetrics.minimised + bottomInset
        case .low: FeedMapMetrics.lowHeight
        case .high: screen - topInset - FeedMapSheetMetrics.inset
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
    /// Minimised: the grabber, the title and its gaps, above the home indicator.
    static let minimised: CGFloat = 76
    static let dragStart: CGFloat = 6
    static let headGap: CGFloat = 12
    static let lineGap: CGFloat = 4
    static let close: CGFloat = 34
    static let skeletonRows = 3
}

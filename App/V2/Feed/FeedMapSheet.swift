import AteKit
import SwiftUI

/// **The sheet under the dish map** (`nearby-map.html`): "Dishes near you" — every dish at the places
/// on screen, best first, paged as you scroll — or, with a pin tapped, that place: its name, where it
/// is, Open place, and its dishes best first. The title says literally what is listed; once the map
/// is dragged off you it is the suburb in the middle ("Dishes in Carlton").
struct FeedMapSheet: View {
    let store: DishMapStore
    let onDish: (UUID) -> Void
    let onPlace: (UUID) -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let place = store.selected {
                    placeHead(place)
                    placeDishes(place)
                } else {
                    Text(store.title.text)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .padding(.bottom, FeedMapSheetMetrics.titleGap)
                        .accessibilityAddTraits(.isHeader)
                    nearby
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, FeedMapSheetMetrics.top)
        }
        .scrollIndicators(.hidden)
        .ateAnimation(AteMotion.fillIn, value: store.selected?.id)
    }

    // MARK: - Dishes near you

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
                Text(FeedMapCopy.empty)
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
        .padding(.bottom, FeedMapSheetMetrics.titleGap)
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

enum FeedMapSheetMetrics {
    static let top: CGFloat = 8
    static let titleGap: CGFloat = 8
    static let headGap: CGFloat = 12
    static let lineGap: CGFloat = 4
    static let close: CGFloat = 34
    static let skeletonRows = 3
}

import AteKit
import SwiftUI

/// **`Search`** — the field, the four segments, and whatever answers them.
///
/// The screen's zero state is the field itself (design rule 1: a screen with nothing to say says
/// nothing) — except on Places, where the artboard draws **Nearby** before a key is pressed. Nearby
/// is a list *ranked* by where the phone is; nothing on it is attached to anything until it is
/// tapped, which is design rule 8 with no asterisk. The phone is asked through the same location
/// path the composer's `PlaceSheet` uses (`AteLocation`), and a refusal costs exactly that list.
///
/// Every row goes somewhere that already exists: a place page, a dish page, somebody's profile. A
/// saved row is the shelf's own ``SavedDishRow``, bookmark and all, because a save is one action
/// wherever it is made.
struct SearchTabScreen: View {
    let store: SearchStore
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    /// The shared ``SaveAction``'s unsave. Returns whether it landed, so the row can come back on a
    /// refusal exactly as it does on the shelf.
    var onUnsave: (SavedDish) async -> Bool = { _ in true }

    @State private var location = AteLocation()
    /// Where the results start on the page — measured, so an empty state can be centred in what is
    /// left below the segments whatever size the title and field were drawn at.
    @State private var resultsTop: CGFloat = 0

    var body: some View {
        ScrollView {
            // `padding:62px 20px 0; gap:16px`.
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                Text("Search")
                    .ateText(.screenTitle)
                    .accessibilityAddTraits(.isHeader)
                // `Search.dc.html`: 52 tall, 18 in, on the chip rather than the field.
                AteSearchField(
                    prompt: "Places, dishes, people",
                    text: Binding(get: { store.query }, set: { store.query = $0 }),
                    height: 52,
                    horizontalPadding: 18,
                    background: AtePalette.automatic.chip,
                    textStyle: .searchField
                )
                .accessibilityIdentifier("search.field")
                scopes
                results
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentTop(62)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
            .coordinateSpace(.named(SearchTabScreen.contentSpace))
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .task { await store.start() }
        .task(id: store.scope) { await askWhereWeAre() }
    }

    /// The one thing this screen asks the phone for, and only while Nearby is what would be shown.
    /// A refusal costs exactly one list and is never mentioned again (no helper copy).
    private func askWhereWeAre() async {
        guard store.scope == .places else { return }
        // Until this answers, Places shows nothing under the pills; a "no" keeps it that way.
        let coordinate = await location.current()
        await store.setOrigin(coordinate.map { SearchOrigin(latitude: $0.latitude, longitude: $0.longitude) })
    }

    // MARK: - Segments

    /// `gap:6px`, each pill 40 tall and 16 in; the current one is ink on the ground (`.ink`).
    private var scopes: some View {
        // Wraps rather than truncating to "P…" once the type outgrows one line.
        AteFlow(spacing: AteMetrics.snug - 2) {
            ForEach(SearchScope.allCases) { scope in
                let isCurrent = scope == store.scope
                Button {
                    store.select(scope)
                } label: {
                    Text(scope.title)
                        .ateText(.controlSmall)
                        .padding(.horizontal, AteMetrics.loose)
                        .atePillHeight(AteMetrics.keyHeight)
                        .background(
                            isCurrent ? AtePalette.automatic.fg : AtePalette.automatic.chip,
                            in: .capsule
                        )
                        .foregroundStyle(isCurrent ? AtePalette.automatic.inverted : AtePalette.automatic.fg)
                        .ateHitArea(.key)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(.key)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("search.scope.\(scope.rawValue)")
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one section label the design draws, and only over the standing list.
            if store.isShowingNearby {
                Text("Nearby")
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .padding(.top, 6)
                    .padding(.bottom, AteMetrics.snug)
            }
            switch store.phase {
            case .idle:
                EmptyView()
            case .loading:
                SearchRowsSkeleton(
                    height: store.scope == .places || store.scope == .people
                        ? PlaceResultRow.height
                        : DishResultRow.height,
                    hasThumbnail: store.scope == .dishes || store.scope == .saved
                )
            case .empty:
                // An empty shelf with nothing typed is the shelf's own state, word for word; an
                // answer that found nothing is the search's.
                centred(AteEmptyState(
                    title: store.scope == .saved && store.isSearching == false
                        ? "Nothing saved\nyet."
                        : "Nothing\nfound."
                ))
            case .failed(let message):
                centred(AteEmptyState(title: message))
            case .ready:
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measured in the scrolled content's own space, so a pull or a bounce does not move it; the
        // content starts under the status bar, which is added back to put it on the page.
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(SearchTabScreen.contentSpace)).minY
        } action: { resultsTop = $0 + AteScreen.safeArea.top }
    }

    /// **The one position rule for a state with nothing under it** (``AteEmptyPlacement``): centred
    /// on the same screen line as every other empty state, measured from where the results begin.
    private func centred(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: resultsTop)
    }

    nonisolated private static let contentSpace = "search.content"

    @ViewBuilder
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            switch store.rows {
            case .places(let places):
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    PlaceResultRow(place: place) { open(place) }
                        .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .dishes(let dishes):
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    DishResultRow(dish: dish) {
                        store.reportOpened()
                        onDish(dish.dishID)
                    }
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .people(let people):
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    PersonResultRow(person: person) {
                        store.reportOpened()
                        onProfile(person.userID)
                    }
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            case .saved(let saved):
                ForEach(Array(saved.enumerated()), id: \.element.id) { index, dish in
                    SavedDishRow(
                        dish: dish,
                        onTap: {
                            store.reportOpened()
                            onDish(dish.dishID)
                        },
                        onUnsave: {
                            Task { await store.unsave(dish) { await onUnsave(dish) } }
                        }
                    )
                    .task { await store.loadMoreIfNeeded(index: index) }
                }
            }
        }
    }

    /// A place row's tap. Every place on this tab is one we hold, so it opens by its UUID for free.
    private func open(_ place: PlaceResult) {
        store.reportOpened()
        onPlace(place.restaurantID)
    }
}

#if DEBUG
#Preview("Search") {
    let service = InMemorySocialService()
    return SearchTabScreen(store: SearchStore(service: service))
    .ateGround()
}
#endif

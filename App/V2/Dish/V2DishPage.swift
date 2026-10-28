import AteKit
import SwiftUI

/// **One dish: its aggregate, and everything anybody has said about it.** Glass back left, the
/// glass bookmark right — Save is the only action. Then the tilted hero, the name and its place, the
/// aggregate (one decimal, stars to the nearest half), then your own review and everyone else's
/// bundled by stars (6 Oct), each review as who and how much with no words (round 4), and under them
/// More to explore and More like this (round 7).
///
/// Opened from a row that knew the dish (round 6), the page draws from it at once and fills in
/// place; opened by id alone, it waits as still shapes and fades in once. The bookmark is the one
/// ``SaveAction``: a dish saved here is saved on every page underneath it.
struct V2DishPage: View {
    let dishID: UUID
    let context: V2PageContext

    @State private var store: DishPageStore
    /// Signed-in reads (round 7): a browser with no session never holds their space open.
    @State private var explore: DishExploreStore?
    @State private var isCollapsed = false
    @State private var titleBottom: CGFloat = 0
    /// The star bands open on this page, by ``DishReviewBand/id``. All closed on arrival.
    @State private var openBands: Set<Int> = []
    /// The dish's place, for the place card: its point and address. Read after the page's own read.
    @State private var place: PlaceSummary?
    /// The place's read has answered (or failed): until then the card waits as a still shape.
    @State private var isPlaceSettled = false
    /// The map's question when Google Maps is on the phone: which app.
    @State private var mapChoice: PlaceMapLink?
    @Environment(\.openURL) private var openURL

    init(dishID: UUID, context: V2PageContext) {
        self.dishID = dishID
        self.context = context
        let services = context.services
        _explore = State(initialValue: context.app.hasSession
            ? DishExploreStore(dishID: dishID, reads: services.dishExplore)
            : nil)
        _store = State(initialValue: DishPageStore(
            dishID: dishID,
            source: context.source,
            dishes: services.dishPages,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            previews: DishPreviews.shared,
            analytics: services.analytics
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.section)
            .coordinateSpace(.named(BrowsePage.content))
        }
        .scrollIndicators(.hidden)
        .ateTitleCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .ateCollapsingTitle(store.summary?.name ?? store.preview?.name, isCollapsed: isCollapsed)
        .toolbar {
            if let summary = store.summary {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save(summary) } label: {
                        (store.isSaved ? AteIcon.saved : AteIcon.save).view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel(store.isSaved ? "Saved \(summary.name)" : "Save \(summary.name)")
                    .accessibilityAddTraits(store.isSaved ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("dish.save")
                }
            }
        }
        .ateRefreshable {
            await store.refresh()
            await store.loadRemaining()
            async let place: Void = loadPlace()
            await explore?.refresh()
            await place
        }
        .task {
            await store.load()
            // The bands count everybody, so the rest of the reviews are read through before the
            // sections under them.
            await store.loadRemaining()
            // After the page's own read, never beside it: the sections below the reviews must not
            // slow the part of the page somebody opened it for.
            guard store.summary != nil else { return }
            async let place: Void = loadPlace()
            await explore?.load()
            await place
        }
        .placeMapsOpening($mapChoice, surface: "dish", analytics: context.services.analytics)
        .accessibilityIdentifier("dish.page")
    }

    // MARK: - The page

    @ViewBuilder
    private var content: some View {
        if let preview = store.preview, store.isSettled == false || store.summary != nil {
            previewed(preview)
        } else {
            switch store.isSettled ? store.header : .loading {
            case .loading:
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    AteDishHero.placeholder
                        .padding(.leading, V2DishMetrics.heroInset)
                    VStack(alignment: .leading, spacing: AtePageHeaderMetrics.lineGap) {
                        AteSkeletonBar(width: V2DishMetrics.nameBar, height: V2DishMetrics.nameBarHeight,
                                       palette: .automatic)
                        AteSkeletonBar(width: V2DishMetrics.placeBar, height: V2DishMetrics.placeBarHeight,
                                       palette: .automatic)
                            .frame(height: AteMetrics.hit, alignment: .top)
                    }
                    .ateSkeletonSweep()
                    .padding(.horizontal, AteMetrics.gutter)
                    AteSkeletonBar(width: V2DishMetrics.aggregateBar, height: V2DishMetrics.aggregateBarHeight,
                                   palette: .automatic)
                        .ateSkeletonSweep()
                        .padding(.horizontal, AteMetrics.gutter)
                }
                .transition(.opacity)
                waitingParts
            case .unavailable:
                AteEmptyState(line: "This dish\nisn't here.", art: .torn)
                    .browseFillsPage()
            case .unreachable:
                BrowsePage.unreachable { Task { await store.retry() } }
                    .browseFillsPage()
            case .ready(let summary):
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    hero(heroPhotos)
                    title(name: summary.name, place: summary.restaurantName, placeID: summary.restaurantID)
                    aggregate(summary)
                }
                .transition(.opacity)
                reviews
                placeCard
                exploreSections
            }
        }
    }

    /// **Opened from a row that knew the dish**: one header, drawn at once from the preview and
    /// filled in place as the reads answer, so the name never re-draws. The reviews wait as still
    /// rows at their own size.
    @ViewBuilder
    private func previewed(_ preview: DishPreview) -> some View {
        let summary = store.isSettled ? store.summary : nil
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            if summary != nil {
                hero(heroPhotos)
            } else if let url = preview.photoURL {
                hero([AtePhoto.remote(url)], tappable: false)
            } else if preview.hasPhotos == true {
                AteDishHero.placeholder
                    .padding(.leading, V2DishMetrics.heroInset)
            }
            title(
                name: summary?.name ?? preview.name,
                place: summary?.restaurantName ?? preview.restaurantName,
                placeID: summary?.restaurantID ?? preview.restaurantID
            )
            if let summary {
                aggregate(summary)
            } else if let score = preview.score {
                AteDishAggregate(score: score, peopleCount: 0)
                    .padding(.horizontal, AteMetrics.gutter)
            } else {
                AteSkeletonBar(width: V2DishMetrics.aggregateBar, height: V2DishMetrics.aggregateBarHeight,
                               palette: .automatic)
                    .ateSkeletonSweep()
                    .padding(.horizontal, AteMetrics.gutter)
            }
        }
        if summary != nil {
            reviews
            placeCard
            exploreSections
        } else {
            waitingParts
        }
    }

    /// The reviews card and the place card as still shapes, while the page's own read is out.
    private var waitingParts: some View {
        VStack(spacing: 0) {
            V2ReviewsCard { AteReviewRowSkeleton() }
                .padding(.top, V2DishMetrics.partGap)
            AtePlaceMapCardSkeleton(hasTitle: true)
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, V2DishMetrics.partGap)
        }
        .transition(.opacity)
    }

    // MARK: - The header

    /// The tilted pair; a photo opens the viewer on it.
    private func hero(_ photos: [AtePhoto], tappable: Bool = true) -> some View {
        AteDishHero(photos: photos, opensViewer: tappable, dishes: heroDishes(photos))
            .padding(.leading, V2DishMetrics.heroInset)
    }

    /// The dish, and the place under it as the door back to the menu it came off. Before the read, a
    /// place the opening row did not know is a still bar at the line's height.
    private func title(name: String, place: String?, placeID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AteExactText(
                text: name, style: .pageHeaderTitle, alignment: .leading, lineLimit: AtePageHeaderMetrics.lines
            )
            .accessibilityAddTraits(.isHeader)
            .browseTitleBottom($titleBottom)
            if let place {
                Button {
                    guard let placeID else { return }
                    PlacePreviews.shared.note(placeID, name: place)
                    context.open(.place(placeID), from: .dish)
                } label: {
                    HStack(spacing: AteMetrics.hairspace) {
                        Text(place)
                            .ateText(.pageHeaderStrong)
                            .foregroundStyle(AtePalette.automatic.fg)
                        AteIcon.chevron.view(size: V2DishMetrics.chevron)
                            .foregroundStyle(AtePalette.automatic.muted)
                    }
                    // The line sits 8 under the name; the rest of the 44 hit falls below it.
                    .padding(.top, AtePageHeaderMetrics.lineGap)
                    .frame(minHeight: AteMetrics.hit, alignment: .top)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(placeID == nil)
                .accessibilityLabel(place)
                .accessibilityIdentifier("dish.place")
            } else {
                AteSkeletonBar(width: V2DishMetrics.placeBar, height: V2DishMetrics.placeBarHeight,
                               palette: .automatic)
                    .ateSkeletonSweep()
                    .padding(.top, AtePageHeaderMetrics.lineGap)
                    .frame(height: AteMetrics.hit, alignment: .top)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
    }

    /// The aggregate, its diet pills beside the people count and the "?" that opens how many people of
    /// each diet logged it (`diet-more.html`): no sentences under it.
    private func aggregate(_ summary: DishSummary) -> some View {
        AteDishAggregate(
            score: summary.score, peopleCount: summary.peopleCount, tags: summary.tags,
            counts: DietCountLine.dish(tags: summary.tags, counts: summary.dietCounts),
            onCounts: { context.services.analytics(DietEvents.countsOpened(surface: .dish)) }
        )
        .padding(.horizontal, AteMetrics.gutter)
    }

    // MARK: - The reviews

    @ViewBuilder
    private var reviews: some View {
        switch store.phase {
        case .loading:
            V2ReviewsCard { AteReviewRowSkeleton() }
                .padding(.top, V2DishMetrics.partGap)
        case .empty:
            // Nobody has written about it yet. Honest, and not an instruction.
            AteEmptyState(line: "Nobody's written\nabout this yet.", art: .rail, size: .section)
                .padding(.vertical, AteMetrics.section)
        case .signedOut:
            AteEmptyState(line: "Nobody's\nsigned in.", art: .bell, size: .section)
                .padding(.vertical, AteMetrics.section)
        case .failed(let message):
            AteEmptyState(line: message, art: .unplugged, size: .section)
                .padding(.vertical, AteMetrics.section)
        case .ready:
            V2ReviewsCard { reviewRows }
                .padding(.top, V2DishMetrics.partGap)
        }
    }

    /// Your own review on its own, first; then everyone else's bundled by stars, best first, each
    /// band opening in place onto its reviews (Eamon, 6 Oct: never every review in one long list).
    @ViewBuilder
    private var reviewRows: some View {
        let mine = store.myReview
        if let mine {
            reviewRow(mine, isFirst: true)
        }
        let bands = store.bands
        ForEach(bands) { band in
            let isFirst = mine == nil && band.id == bands.first?.id
            AteReviewBand(
                title: band.title,
                countLine: band.countLine,
                faces: band.reviews.compactMap { review in
                    review.author.map {
                        AteReviewFace(
                            id: $0.id, handle: $0.username, avatarURL: $0.avatarURL.flatMap(URL.init(string:))
                        )
                    }
                },
                isOpen: isOpen(band),
                isFirst: isFirst,
                identifier: "dish.band.\(band.stars.map(String.init) ?? "none")"
            ) {
                ForEach(band.reviews) { review in
                    reviewRow(review, isFirst: false)
                }
            }
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AteMetrics.regular)
        }
    }

    private func reviewRow(_ review: DishReview, isFirst: Bool) -> some View {
        AteReviewRow(
            userID: review.author?.id ?? review.reviewID,
            name: Self.name(of: review),
            handle: review.author?.username ?? "?",
            rating: review.score,
            avatarURL: review.author?.avatarURL.flatMap(URL.init(string:)),
            isFirst: isFirst,
            // Your own "You" is not a door: the You tab is your profile.
            onProfile: review.isMine ? nil : review.author.map { author in { openProfile(author.id) } },
            // A legacy review has no visit to open.
            onOpen: review.entryID.map { entryID in { openEntry(entryID) } }
        )
    }

    private func isOpen(_ band: DishReviewBand) -> Binding<Bool> {
        Binding(
            get: { openBands.contains(band.id) },
            set: { open in
                if open {
                    openBands.insert(band.id)
                    context.services.analytics(DetailEvents.dishBandOpened(stars: band.stars))
                } else {
                    openBands.remove(band.id)
                }
            }
        )
    }

    /// "You" for your own, the handle for everyone else's; an author who is blocked or gone loses
    /// their name, never their review.
    private static func name(of review: DishReview) -> String {
        if review.isMine { return "You" }
        guard let username = review.author?.username else { return "Someone" }
        return "@\(username)"
    }

    private func openEntry(_ entryID: UUID) {
        context.services.analytics(DetailEvents.dishReviewOpened(target: .entry))
        context.open(.entry(EntryRoute(entryID: entryID)), from: .dish)
    }

    private func openProfile(_ userID: UUID) {
        context.services.analytics(DetailEvents.dishReviewOpened(target: .profile))
        context.open(.profile(userID), from: .dish)
    }

    // MARK: - Under the reviews

    @ViewBuilder
    private var exploreSections: some View {
        if let explore, store.isSettled, store.summary != nil {
            V2DishExplore(store: explore, context: context)
                .transition(.opacity)
        }
    }

    // MARK: - Save

    private func save(_ summary: DishSummary) {
        Task {
            await context.saves.toggle(
                dishID: summary.dishID,
                // Made on the dish itself, not off somebody's visit: the provenance is nothing.
                entryID: nil,
                isSaved: store.isSaved,
                source: .dish
            )
        }
    }
}

enum V2DishMetrics {
    /// The hero sits 2 past the gutter (the cluster insets its own 6 for the tilt).
    static let heroInset: CGFloat = AteMetrics.gutter - AteDishHeroMetrics.inset + AteMetrics.hairspace
    static let chevron: CGFloat = 15
    static let nameBar: CGFloat = 240
    static let nameBarHeight: CGFloat = 36
    static let placeBar: CGFloat = 110
    static let placeBarHeight: CGFloat = 14
    static let aggregateBar: CGFloat = 160
    static let aggregateBarHeight: CGFloat = 44
    /// Between the page's parts: the header, the reviews, the place (`gap-m`, 22; Eamon 28 Oct: the
    /// page was spaced out).
    static let partGap: CGFloat = 22
}

private extension V2DishPage {
    // MARK: - The place

    /// **Where it is** (`dish-page-place-map.html`, A, Eamon 28 Oct): the place's map, its name and
    /// address, the same card the place page shows. The map opens Maps; the name opens the place.
    @ViewBuilder
    var placeCard: some View {
        if store.isSettled, place == nil, isPlaceSettled == false {
            AtePlaceMapCardSkeleton(hasTitle: true)
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, V2DishMetrics.partGap)
                .transition(.opacity)
        } else if let place, store.isSettled {
            let link = PlaceMapLink(place)
            AtePlaceMapCard(
                link: link,
                title: place.name,
                onMap: {
                    PlaceMaps.show(link, choice: $mapChoice, surface: "dish",
                                   analytics: context.services.analytics, openURL: openURL)
                },
                onPlace: { openPlace(place) }
            )
            .padding(.horizontal, AteMetrics.listGutter)
            .padding(.top, V2DishMetrics.partGap)
            .transition(.opacity)
        }
    }

    /// The place's own read, for its point and address. A failure leaves the card off the page: the
    /// name under the dish's still opens the place.
    func loadPlace() async {
        guard let restaurantID = store.summary?.restaurantID else {
            isPlaceSettled = true
            return
        }
        let summary = try? await context.services.placePages.placeSummary(restaurantID: restaurantID)
        withAnimation(AteMotion.fillIn) {
            if let summary { place = summary }
            isPlaceSettled = true
        }
    }

    func openPlace(_ place: PlaceSummary) {
        context.services.analytics(DetailEvents.dishPlaceCardOpened())
        PlacePreviews.shared.note(place.restaurantID, name: place.name)
        context.open(.place(place.restaurantID), from: .dish)
    }

    /// Every hero photo is this dish: the viewer names it, with who took it (when their review has
    /// arrived) and where.
    func heroDishes(_ photos: [AtePhoto]) -> AtePhotoDishes? {
        guard let summary = store.summary else { return nil }
        let place = summary.restaurantName
        var bylines: [String: String] = [:]
        for photo in summary.photos {
            let author = photo.entryID.flatMap { entry in store.reviews.first { $0.entryID == entry }?.author }
            if let line = AtePhotoDishByline.line(who: author.map { "@\($0.username)" }, place: place) {
                bylines[photo.url] = line
            }
        }
        let byline = AtePhotoDishByline.line(who: nil, place: place)
        var shared: [String: (box: PhotoDishBox, others: [DishPhoto.Other])] = [:]
        for photo in summary.photos where shared[photo.url] == nil {
            if let box = photo.box { shared[photo.url] = (box, photo.others) }
        }
        return AtePhotoDishes.one(summary.name, photos: photos, byline: byline, bylines: bylines, shared: shared)
    }

    /// The hero's photos; one this dish shares with other dishes is cropped onto it (0083).
    var heroPhotos: [AtePhoto] {
        let boxes = Dictionary(
            (store.summary?.photos ?? []).compactMap { photo in photo.box.map { (photo.url, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return store.heroPhotoURLs.map { url in
            var photo = AtePhoto.remote(url)
            photo.focus = boxes[url]
            return photo
        }
    }
}

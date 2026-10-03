import AteKit
import SwiftUI

/// What a row on the edition can do — handed down from ``FeedRoot`` so the sections draw and never
/// decide.
@MainActor
struct FeedEditionActions {
    /// Pushes a page on the Feed's stack.
    let push: (Route) -> Void
    /// A dish's bookmark anywhere but a slip, and the section it was tapped in.
    let save: (FeedDish, FeedEvents.Section) -> Void
    /// A latest receipt's dish row.
    let saveFromSlip: (EntryCard, AteSlip.Dish) -> Void
    /// A slip, long-pressed: its actions sheet.
    let act: (EntryCard) -> Void

    /// A dish's page, with what this row printed noted so it opens on it.
    func open(_ dish: FeedDish) {
        DishPreviews.shared.note(DishPreview(
            dishID: dish.dishID, name: dish.name, restaurantID: dish.restaurantID,
            restaurantName: dish.restaurantName, score: dish.score, photoURL: dish.coverURLString
        ))
        push(.dish(dish.dishID))
    }
}

/// **The edition, section by section** — in the order Eamon set: The Top Ate, Because you loved…,
/// New to the record, a shelf per craving (and the row that chooses them while there are none),
/// the latest receipts, then the end. Loading is the Top Ate's skeleton; nothing at all is the one
/// empty state, or the unreachable one with its retry.
struct FeedEditionSections: View {
    let edition: FeedEditionStore
    let latest: EntryListStore
    let isSignedIn: Bool
    let actions: FeedEditionActions
    let onChooseCravings: () -> Void

    var body: some View {
        if edition.isSettled == false {
            loading
        } else if edition.isEmpty, latest.entries.isEmpty, latest.phase != .loading {
            nothing
        } else {
            sections
            latestReceipts
            AteEndRule(line: "You're caught up")
                .accessibilityIdentifier("feed.caughtUp")
                .onAppear { edition.sectionAppeared(.caughtUp) }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var loading: some View {
        AteSectionHeading(title: FeedEditionCopy.topAte, identifier: "feed.section.topAte")
            .padding(.top, AteSectionHeadingMetrics.firstTop - AteSectionHeadingMetrics.top)
        VStack(spacing: 0) {
            AteSkeleton(kind: .hero)
                .padding(.bottom, AteMetrics.tight)
            ForEach(2...FeedEditionStore.topAteLimit, id: \.self) { _ in
                AteSkeleton(kind: .rankedRow)
            }
        }
        .padding(.horizontal, AteMetrics.loose)
        .transition(.opacity)
    }

    /// Nobody has written anything here yet, or Ate could not be reached. The cravings row still
    /// stands, so a follower can still choose.
    @ViewBuilder
    private var nothing: some View {
        Group {
            if case .failed = latest.phase {
                AteEmptyState(line: "Couldn't\nreach Ate.", pill: ("Try again", retry))
                    .accessibilityIdentifier("state.unreachable")
            } else {
                AteEmptyState(line: "Nobody's written\nanything yet.")
                    .accessibilityIdentifier("state.empty")
            }
        }
        .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
        chooseCravings
    }

    private func retry() {
        Task {
            async let sections: Void = edition.refresh()
            await latest.refresh()
            await sections
        }
    }

    // MARK: - The edition

    @ViewBuilder
    private var sections: some View {
        if edition.showsTopAte {
            AteSectionHeading(title: FeedEditionCopy.topAte, identifier: "feed.section.topAte")
                .padding(.top, AteSectionHeadingMetrics.firstTop - AteSectionHeadingMetrics.top)
                .onAppear { edition.sectionAppeared(.topAte) }
            FeedTopAte(lines: edition.topAte, actions: actions)
        }
        if edition.showsLoved, let loved = edition.loved {
            AteSectionHeading(title: loved.title, identifier: "feed.section.loved")
                .onAppear { edition.sectionAppeared(.becauseYouLoved) }
            FeedShelf(dishes: loved.dishes, section: .becauseYouLoved, actions: actions)
        }
        if edition.showsNew {
            AteSectionHeading(title: FeedEditionCopy.new, identifier: "feed.section.new")
                .onAppear { edition.sectionAppeared(.newToRecord) }
            FeedNewRows(rows: edition.newDishes, actions: actions)
        }
        ForEach(edition.visibleShelves) { shelf in
            AteSectionHeading(
                title: shelf.craving.title,
                onSeeAll: { actions.push(.tag(shelf.craving.route(city: edition.city))) },
                identifier: "feed.shelf"
            )
            .onAppear { edition.sectionAppeared(.cravingShelf) }
            FeedShelf(dishes: shelf.dishes, section: .cravingShelf, actions: actions)
        }
        chooseCravings
    }

    /// "Choose your cravings" — only while you follow none; the heart in the bar is the door after.
    @ViewBuilder
    private var chooseCravings: some View {
        if edition.showsChooseCravings, edition.cravings.isEmpty {
            AteChooseRow(title: "Choose your cravings", identifier: "feed.cravings.choose",
                         action: onChooseCravings)
                .padding(.horizontal, AteMetrics.loose)
                .padding(.top, AteSectionHeadingMetrics.top)
        }
    }

    /// A short run of the feed's own slips — the one slip, the Feed's surface — capped.
    @ViewBuilder
    private var latestReceipts: some View {
        let entries = Array(latest.entries.prefix(FeedEditionStore.latestCap))
        if entries.isEmpty == false {
            AteSectionHeading(title: FeedEditionCopy.latest, identifier: "feed.section.latest")
                .onAppear { edition.sectionAppeared(.latestReceipts) }
            ForEach(entries) { entry in
                FeedSlip(entry: entry, actions: actions)
                    .task { await AtePrefetch.photos(after: entry, in: entries) }
                    .padding(.top, entry.id == entries.first?.id ? 0 : AteMetrics.slipGap)
            }
        }
    }
}

enum FeedEditionCopy {
    static let topAte = "The Top Ate"
    static let new = "New to the record"
    static let latest = "Latest receipts"
    /// How much of the screen an empty or unreachable state takes: the band between the bar and
    /// the tab bar, less the bars themselves.
    static let emptyShare: CGFloat = 0.8
}

// MARK: - The Top Ate

/// The Top Ate as a hero chart (Eamon, 3 Oct): #1 a full photo card with no numeral, #2 to #8 as
/// ranked rows.
struct FeedTopAte: View {
    let lines: [TopAteLine]
    let actions: FeedEditionActions

    var body: some View {
        let letters = DishLetter.neighbourly(lines.map { ($0.dish.dishID, $0.dish.name) })
        VStack(spacing: 0) {
            if let first = lines.first {
                let dish = first.dish
                AteHeroCard(
                    photo: .dish(letters[0], cover: dish.coverURLString),
                    name: dish.name,
                    place: dish.restaurantName,
                    score: dish.score.map(AteScore.average),
                    isSaved: dish.isSaved,
                    onOpen: { actions.open(dish) },
                    onSave: { actions.save(dish, .topAte) }
                )
                .padding(.bottom, AteMetrics.tight)
            }
            ForEach(Array(lines.enumerated().dropFirst()), id: \.element.id) { index, line in
                let dish = line.dish
                AteRankedRow(
                    rank: index + 1,
                    photo: .dish(letters[index], cover: dish.coverURLString),
                    name: dish.name,
                    place: dish.restaurantName,
                    score: dish.score.map(AteScore.average),
                    isSaved: dish.isSaved,
                    isLast: index == lines.count - 1,
                    onOpen: { actions.open(dish) },
                    onSave: { actions.save(dish, .topAte) }
                )
            }
        }
        .padding(.horizontal, AteMetrics.loose)
        .accessibilityIdentifier("feed.topAte")
    }
}

// MARK: - Shelves

/// Because you loved… and each craving: shelf cards running off the trailing edge.
struct FeedShelf: View {
    let dishes: [FeedDish]
    let section: FeedEvents.Section
    let actions: FeedEditionActions

    var body: some View {
        let tiles = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.name) })
        let letters = Dictionary(zip(dishes.map(\.dishID), tiles), uniquingKeysWith: { first, _ in first })
        AteShelf(items: dishes) { dish in
            AteShelfCard(
                photo: Self.photo(dish, letter: letters[dish.dishID]),
                name: dish.name,
                place: dish.restaurantName,
                score: dish.score.map(AteScore.average),
                isSaved: dish.isSaved,
                onOpen: { actions.open(dish) },
                onSave: { actions.save(dish, section) }
            )
        }
    }

    private static func photo(_ dish: FeedDish, letter: DishLetter?) -> AtePhoto {
        if let letter { return AtePhoto.dish(letter, cover: dish.coverURLString) }
        return AtePhoto.dish(dish.dishID, name: dish.name, cover: dish.coverURLString)
    }
}

// MARK: - New to the record

struct FeedNewRows: View {
    let rows: [NewDish]
    let actions: FeedEditionActions

    var body: some View {
        let letters = DishLetter.neighbourly(rows.map { ($0.dish.dishID, $0.dish.name) })
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let dish = row.dish
                AteNewDishRow(
                    photo: .dish(letters[index], cover: dish.coverURLString),
                    name: dish.name,
                    place: dish.restaurantName,
                    badge: Self.badge(row.kind),
                    isSaved: dish.isSaved,
                    isLast: index == rows.count - 1,
                    onOpen: { actions.open(dish) },
                    onSave: { actions.save(dish, .newToRecord) }
                )
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
    }

    /// A secret 6 and a 5.0 are their tokens; anything else is new.
    static func badge(_ kind: NewDish.Kind) -> AteNewDishRow.Badge {
        switch kind {
        case .six: .score(.personal(.blownAway))
        case .five: .score(.personal(.perfect))
        case .new: .new
        }
    }
}

// MARK: - Latest receipts

/// One latest receipt: the approved slip on the Feed's surface, and a long-press for its actions.
struct FeedSlip: View {
    let entry: EntryCard
    let actions: FeedEditionActions

    var body: some View {
        AteEntrySlip(
            slip: EntrySlipPresentation.feed(entry),
            surface: .feed,
            onOpen: { actions.push(.entry(EntryRoute(entry))) },
            onProfile: { actions.push(.profile(entry.authorID)) },
            onSave: { actions.saveFromSlip(entry, $0) },
            onPlace: { actions.push(.place($0)) },
            onDish: { actions.push(.dish($0.dishID)) },
            identifier: "feed.slip"
        )
        .ateCardWidth()
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            AteHaptics.key()
            actions.act(entry)
        })
        .accessibilityAction(named: "Actions") { actions.act(entry) }
    }
}

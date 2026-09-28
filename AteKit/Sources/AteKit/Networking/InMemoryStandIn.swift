import Foundation

/// **An in-memory stand-in for a service** — previews, the XCUITest drive, `-ate-preview-data`.
///
/// Only a type that says it is one gets the defaults below, where every requirement it does not
/// implement throws ``StandInUnsupported``. So a new RPC needs no edit to the stand-ins, and a live
/// client, which never conforms, still has to implement every requirement itself.
public protocol InMemoryStandIn {}

/// A stand-in was asked for something it does not do.
public struct StandInUnsupported: Error, Equatable, Sendable {
    public let function: String

    public init(_ function: String = #function) {
        self.function = function
    }
}

public extension EntryService where Self: InMemoryStandIn {
    func viewer() async throws -> ViewerProfile { throw StandInUnsupported() }
    func authorID() async throws -> UUID { throw StandInUnsupported() }
    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard { throw StandInUnsupported() }
    func attach(photo: EntryPhotoUpload) async throws { throw StandInUnsupported() }
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        throw StandInUnsupported()
    }
    func entry(id: UUID) async throws -> EntryCard { throw StandInUnsupported() }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        throw StandInUnsupported()
    }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard { throw StandInUnsupported() }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws { throw StandInUnsupported() }
    func setTags(reviewID: UUID, tags: [DietTag]) async throws { throw StandInUnsupported() }
    func updateBody(entryID: UUID, body: String) async throws { throw StandInUnsupported() }
}

public extension JournalQuerying where Self: InMemoryStandIn {
    func myEntries(_ query: JournalQuery, after cursor: JournalCursor?, pageSize: Int) async throws
        -> JournalQueryPage { throw StandInUnsupported() }
}

public extension EntryFeedReading where Self: InMemoryStandIn {
    func feedPage(after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?) async throws
        -> Page<EntryCard> { throw StandInUnsupported() }
}

public extension DishSaving where Self: InMemoryStandIn {
    func save(dishID: UUID, sourceEntryID: UUID?) async throws { throw StandInUnsupported() }
    func unsave(dishID: UUID) async throws { throw StandInUnsupported() }
    @discardableResult
    func saveEntryDishes(entryID: UUID) async throws -> Int { throw StandInUnsupported() }
    func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        throw StandInUnsupported()
    }
}

public extension ProfileReading where Self: InMemoryStandIn {
    func profile(id: UUID) async throws -> ProfileSummary { throw StandInUnsupported() }
    func entriesPage(authorID: UUID, after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        throw StandInUnsupported()
    }
    func block(userID: UUID) async throws { throw StandInUnsupported() }
    func report(profileID: UUID, reason: String?, note: String?) async throws { throw StandInUnsupported() }
    func report(entryID: UUID, reason: String?, note: String?) async throws { throw StandInUnsupported() }
}

public extension SearchReading where Self: InMemoryStandIn {
    func nearbyPlaces(origin: SearchOrigin, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult> { throw StandInUnsupported() }
    func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PlaceResult> {
        throw StandInUnsupported()
    }
    func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<DishResult> {
        throw StandInUnsupported()
    }
    func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PersonResult> {
        throw StandInUnsupported()
    }
    func savedDishes(matching query: String?, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<SavedDish> { throw StandInUnsupported() }
}

public extension PlacePageReading where Self: InMemoryStandIn {
    func placeSummary(restaurantID: UUID) async throws -> PlaceSummary { throw StandInUnsupported() }
    func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws
        -> MenuDishPage { throw StandInUnsupported() }
    func entriesAtPlace(restaurantID: UUID, scope: PlaceEntryScope, after cursor: PageCursor?, pageSize: Int)
        async throws -> Page<EntryCard> { throw StandInUnsupported() }
}

public extension DishPageReading where Self: InMemoryStandIn {
    func dishSummary(dishID: UUID) async throws -> DishSummary { throw StandInUnsupported() }
    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage {
        throw StandInUnsupported()
    }
    func isDishSaved(dishID: UUID) async throws -> Bool { throw StandInUnsupported() }
}

public extension StatsReading where Self: InMemoryStandIn {
    func viewerID() async throws -> UUID { throw StandInUnsupported() }
    func summary(userID: UUID) async throws -> ProfileSummary { throw StandInUnsupported() }
    func histogram(userID: UUID) async throws -> ScoreHistogram { throw StandInUnsupported() }
    func dishes(userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int) async throws
        -> Page<ScoredDish> { throw StandInUnsupported() }
    func months(userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int) async throws
        -> [StatementMonthSummary] { throw StandInUnsupported() }
    func statement(userID: UUID, month: StatementMonth, timeZone: TimeZone) async throws -> MonthlyStatement {
        throw StandInUnsupported()
    }
}

public extension AccountServing where Self: InMemoryStandIn {
    func isHandleAvailable(_ handle: String) async throws -> Bool { throw StandInUnsupported() }
    func setHandle(_ handle: String) async throws { throw StandInUnsupported() }
    func setName(_ name: String) async throws { throw StandInUnsupported() }
    func account() async throws -> AccountProfile { throw StandInUnsupported() }
    @discardableResult
    func setAvatar(_ image: AvatarUpload) async throws -> URL { throw StandInUnsupported() }
    func blockedPeople(after cursor: PageCursor?, pageSize: Int) async throws -> Page<BlockedPerson> {
        throw StandInUnsupported()
    }
    func unblock(userID: UUID) async throws { throw StandInUnsupported() }
    func deleteAccount() async throws -> AccountDeletion { throw StandInUnsupported() }
    func signOut() async throws { throw StandInUnsupported() }
}

public extension PlaceDirectory where Self: InMemoryStandIn {
    func search(_ query: String) async throws -> [PlaceSuggestion] { throw StandInUnsupported() }
    func recents(limit: Int) async throws -> [PlaceSuggestion] { throw StandInUnsupported() }
    func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] { throw StandInUnsupported() }
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef { throw StandInUnsupported() }
    func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef { throw StandInUnsupported() }
    func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] { throw StandInUnsupported() }
}

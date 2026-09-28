import Foundation
import Testing

@testable import AteKit

/// **A test double for a service protocol.** A fake that conforms implements only the calls its test
/// is about; anything else it is asked for fails that test and throws. So a new RPC needs no edit to
/// the fakes, and a fake that is quietly reached for something it never promised cannot pass.
protocol TestFake {}

/// A fake was asked for something it does not implement.
struct Unimplemented: Error, CustomStringConvertible {
    let function: String
    var description: String { "\(function) is not implemented by this fake" }
}

/// Records the call as a test failure, then throws.
func unimplemented(_ function: String = #function) throws -> Never {
    Issue.record(Comment(rawValue: Unimplemented(function: function).description))
    throw Unimplemented(function: function)
}

extension EntryService where Self: TestFake {
    func viewer() async throws -> ViewerProfile { try unimplemented() }
    func authorID() async throws -> UUID { try unimplemented() }
    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard { try unimplemented() }
    func attach(photo: EntryPhotoUpload) async throws { try unimplemented() }
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome { try unimplemented() }
    func entry(id: UUID) async throws -> EntryCard { try unimplemented() }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> { try unimplemented() }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard { try unimplemented() }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws { try unimplemented() }
    func setTags(reviewID: UUID, tags: [DietTag]) async throws { try unimplemented() }
    func updateBody(entryID: UUID, body: String) async throws { try unimplemented() }
}

extension JournalQuerying where Self: TestFake {
    func myEntries(_ query: JournalQuery, after cursor: JournalCursor?, pageSize: Int) async throws
        -> JournalQueryPage { try unimplemented() }
}

extension EntryFeedReading where Self: TestFake {
    func feedPage(after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?) async throws
        -> Page<EntryCard> { try unimplemented() }
}

extension DishSaving where Self: TestFake {
    func save(dishID: UUID, sourceEntryID: UUID?) async throws { try unimplemented() }
    func unsave(dishID: UUID) async throws { try unimplemented() }
    @discardableResult
    func saveEntryDishes(entryID: UUID) async throws -> Int { try unimplemented() }
    func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        try unimplemented()
    }
}

extension ProfileReading where Self: TestFake {
    func profile(id: UUID) async throws -> ProfileSummary { try unimplemented() }
    func entriesPage(authorID: UUID, after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        try unimplemented()
    }
    func block(userID: UUID) async throws { try unimplemented() }
    func report(profileID: UUID, reason: String?, note: String?) async throws { try unimplemented() }
    func report(entryID: UUID, reason: String?, note: String?) async throws { try unimplemented() }
}

extension ViewerProfileReading where Self: TestFake {
    func viewer() async throws -> ViewerProfile { try unimplemented() }
}

extension SearchReading where Self: TestFake {
    func nearbyPlaces(origin: SearchOrigin, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult> { try unimplemented() }
    func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PlaceResult> {
        try unimplemented()
    }
    func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<DishResult> {
        try unimplemented()
    }
    func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PersonResult> {
        try unimplemented()
    }
    func savedDishes(matching query: String?, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<SavedDish> { try unimplemented() }
}

extension PlacePageReading where Self: TestFake {
    func placeSummary(restaurantID: UUID) async throws -> PlaceSummary { try unimplemented() }
    func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws
        -> MenuDishPage { try unimplemented() }
    func entriesAtPlace(restaurantID: UUID, scope: PlaceEntryScope, after cursor: PageCursor?, pageSize: Int)
        async throws -> Page<EntryCard> { try unimplemented() }
}

extension DishPageReading where Self: TestFake {
    func dishSummary(dishID: UUID) async throws -> DishSummary { try unimplemented() }
    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage {
        try unimplemented()
    }
    func isDishSaved(dishID: UUID) async throws -> Bool { try unimplemented() }
}

extension StatsReading where Self: TestFake {
    func viewerID() async throws -> UUID { try unimplemented() }
    func summary(userID: UUID) async throws -> ProfileSummary { try unimplemented() }
    func histogram(userID: UUID) async throws -> ScoreHistogram { try unimplemented() }
    func dishes(userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int) async throws
        -> Page<ScoredDish> { try unimplemented() }
    func months(userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int) async throws
        -> [StatementMonthSummary] { try unimplemented() }
    func statement(userID: UUID, month: StatementMonth, timeZone: TimeZone) async throws -> MonthlyStatement {
        try unimplemented()
    }
}

extension AccountServing where Self: TestFake {
    func isHandleAvailable(_ handle: String) async throws -> Bool { try unimplemented() }
    func setHandle(_ handle: String) async throws { try unimplemented() }
    func setName(_ name: String) async throws { try unimplemented() }
    func account() async throws -> AccountProfile { try unimplemented() }
    @discardableResult
    func setAvatar(_ image: AvatarUpload) async throws -> URL { try unimplemented() }
    func blockedPeople(after cursor: PageCursor?, pageSize: Int) async throws -> Page<BlockedPerson> {
        try unimplemented()
    }
    func unblock(userID: UUID) async throws { try unimplemented() }
    func deleteAccount() async throws -> AccountDeletion { try unimplemented() }
    func signOut() async throws { try unimplemented() }
}

extension PlaceDirectory where Self: TestFake {
    func search(_ query: String) async throws -> [PlaceSuggestion] { try unimplemented() }
    func recents(limit: Int) async throws -> [PlaceSuggestion] { try unimplemented() }
    func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] { try unimplemented() }
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef { try unimplemented() }
    func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef { try unimplemented() }
    func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] { try unimplemented() }
}

extension PlacesSearching where Self: TestFake {
    func autocomplete(query: String, origin: SearchOrigin?, sessionToken: PlacesSessionToken?) async throws
        -> PlacesAutocompleteResponse { try unimplemented() }
    func nearby(origin: SearchOrigin, radiusMeters: Double?) async throws -> PlacesNearbyResponse {
        try unimplemented()
    }
    func details(googlePlaceID: String, sessionToken: PlacesSessionToken?) async throws -> PlacesDetailsResponse {
        try unimplemented()
    }
}

extension RestaurantSearchProviding where Self: TestFake {
    func nearby(origin: SearchOrigin) async throws -> [RestaurantRowModel] { try unimplemented() }
    func recents(limit: Int) async throws -> [RestaurantRowModel] { try unimplemented() }
    func search(query: String, origin: SearchOrigin?, sessionToken: PlacesSessionToken?) async throws
        -> [RestaurantRowModel] { try unimplemented() }
    func resolve(_ row: RestaurantRowModel, sessionToken: PlacesSessionToken?) async throws -> PickedRestaurant {
        try unimplemented()
    }
    func addManual(name: String, city: String?, cuisine: String?) async throws -> PickedRestaurant {
        try unimplemented()
    }
}

extension FeedEditionReading where Self: TestFake {
    func topAte(city: String?, limit: Int) async throws -> [TopAteLine] { try unimplemented() }
    func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf? { try unimplemented() }
    func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish] { try unimplemented() }
    func myCravings() async throws -> [Craving] { try unimplemented() }
    func cravingOptions() async throws -> [CravingOption] { try unimplemented() }
    func setCravings(_ cravings: [Craving]) async throws -> [Craving] { try unimplemented() }
    func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish] {
        try unimplemented()
    }
}

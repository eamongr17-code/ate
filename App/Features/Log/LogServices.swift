import AteKit
import Foundation
import TelemetryDeck

/// Everything the log flow needs from the outside world, in one value — the same shape as
/// ``SearchServices``, and for the same reason: previews and tests substitute the protocols, the app
/// calls ``live(api:)``.
struct LogServices: Sendable {
    /// Handed straight to ``SearchPicker`` for the WHERE and WHAT steps. Built by ``live(api:)`` with
    /// the provenance decorators wrapped around the real services (see ``LogPickProvenance``).
    let search: SearchServices
    let poster: any ReviewPosting
    let photos: any ReviewPhotoUploading
    let drafts: any LogDraftStoring
    /// Shared between the sheet and the foreground retry — one instance, or the retry can't tell
    /// that a sitting is open (see ``LogDraftCheckout``).
    let checkout: LogDraftCheckout
    let telemetry: any LogTelemetrySink
    /// Who the receipt is by. Optional — a receipt without a byline is fine; a blocked post is not.
    let currentUser: @Sendable () async -> ReceiptModel.Author?
    /// The reviewer id every posted row carries. Throwing, not optional: posting without a session
    /// must fail loudly, not write anonymous rows.
    let currentUserID: @Sendable () async throws -> UUID
    let provenance: LogPickProvenance

    init(
        search: SearchServices,
        poster: any ReviewPosting,
        photos: any ReviewPhotoUploading,
        drafts: any LogDraftStoring,
        checkout: LogDraftCheckout = LogDraftCheckout(),
        telemetry: any LogTelemetrySink = TelemetryDeckLogSink(),
        currentUser: @escaping @Sendable () async -> ReceiptModel.Author? = { nil },
        currentUserID: @escaping @Sendable () async throws -> UUID = { throw AteAPIError.notAuthenticated },
        provenance: LogPickProvenance = LogPickProvenance()
    ) {
        self.search = search
        self.poster = poster
        self.photos = photos
        self.drafts = drafts
        self.checkout = checkout
        self.telemetry = telemetry
        self.currentUser = currentUser
        self.currentUserID = currentUserID
        self.provenance = provenance
    }

    /// The §6.4 foreground retry, built from the same seams the sheet uses — so a test can hand it
    /// fakes and the app can't accidentally give it a second draft store.
    func makeRetryRunner() -> LogPostRetryRunner {
        LogPostRetryRunner(
            drafts: drafts,
            poster: poster,
            currentUserID: currentUserID,
            telemetry: telemetry,
            checkout: checkout
        )
    }

    static func live(api: AteAPIClient) -> LogServices {
        let provenance = LogPickProvenance()
        return LogServices(
            search: SearchServices(
                restaurants: ProvenanceRestaurantSearch(
                    base: RestaurantSearchService(api: api),
                    provenance: provenance
                ),
                dishes: ProvenanceDishSearch(
                    base: DishSearchService(api: api),
                    provenance: provenance
                )
            ),
            poster: ReviewPostingService(api: api),
            photos: ReviewPhotoUploadService(api: api),
            drafts: FileLogDraftStore(),
            currentUser: { await Self.author(api: api) },
            currentUserID: { try await api.requireCurrentUserID() },
            provenance: provenance
        )
    }

    private static func author(api: AteAPIClient) async -> ReceiptModel.Author? {
        guard let id = api.currentUserID,
              let user = try? await api.fetchByID(User.self, id: id)
        else { return nil }
        return ReceiptModel.Author(
            name: user.name,
            handle: user.handle,
            avatarURLString: user.avatarURLString
        )
    }
}

/// The only untestable part of the telemetry path.
struct TelemetryDeckLogSink: LogTelemetrySink {
    func send(_ event: LogEvent) {
        TelemetryDeck.signal(event.name, parameters: event.parameters)
    }
}

// MARK: - Provenance

/// Remembers **which section a picked row came from**, so `log_where_resolved(source:)` and
/// `log_what_resolved(source:)` carry the truth instead of a guess.
///
/// The picker hands its host a `PickedRestaurant` / `PickedDish` — an id and a name, with no memory
/// of whether it was tapped under "Nearby" or typed into the search field. Rather than fork
/// ``SearchPicker`` to widen that payload (it is shared with the Search tab, and its API is not mine
/// to change), the log wraps the *services* the picker reads from and records what each call
/// returned. The picker is untouched and the funnel keeps every property the brief names.
///
/// Follow-up flagged to the lead: the durable fix is for the picker's selection payload to carry its
/// own provenance, at which point this class deletes itself.
final class LogPickProvenance: @unchecked Sendable {
    private let lock = NSLock()
    private var restaurantSections: [String: LogWhereSource] = [:]
    private var historyDishIDs: Set<UUID> = []
    private var whereSource: LogWhereSource?
    private var whatSource: LogWhatSource?

    init() {}

    // MARK: Recording (called from the decorated services)

    func recordRestaurantRows(_ rows: [RestaurantRowModel], source: LogWhereSource) {
        lock.withLock {
            for row in rows { restaurantSections[row.id] = source }
        }
    }

    /// Search results carry their own kind: a Places prediction resolves through `op=details`, a
    /// manual row is already a row.
    func recordSearchResults(_ rows: [RestaurantRowModel]) {
        lock.withLock {
            for row in rows {
                restaurantSections[row.id] = row.telemetryKind == "place" ? .searchPlace : .searchManual
            }
        }
    }

    func recordRestaurantResolved(rowID: String) {
        lock.withLock { whereSource = restaurantSections[rowID] ?? .searchManual }
    }

    func recordRestaurantAddedManually() {
        lock.withLock { whereSource = .addedManual }
    }

    func recordHistoryDishes(_ rows: [DishRowModel]) {
        lock.withLock { historyDishIDs.formUnion(rows.map(\.dishID)) }
    }

    func recordDishSelected(id: UUID, wasCreated: Bool) {
        lock.withLock {
            whatSource = wasCreated ? .newDish : (historyDishIDs.contains(id) ? .history : .menu)
        }
    }

    // MARK: Reading (called from the session model, once per resolution)

    /// Consumes the recorded source. Falls back rather than dropping the event: a funnel step with a
    /// best-guess source is still countable; a missing step is a hole in the funnel.
    func takeWhereSource() -> LogWhereSource {
        lock.withLock {
            defer { whereSource = nil }
            return whereSource ?? .searchManual
        }
    }

    func takeWhatSource() -> LogWhatSource {
        lock.withLock {
            defer { whatSource = nil }
            return whatSource ?? .menu
        }
    }
}

/// Pass-through restaurant search that notes which section each row came from.
struct ProvenanceRestaurantSearch: RestaurantSearchProviding {
    let base: any RestaurantSearchProviding
    let provenance: LogPickProvenance

    func nearby(origin: SearchOrigin) async throws -> [RestaurantRowModel] {
        let rows = try await base.nearby(origin: origin)
        provenance.recordRestaurantRows(rows, source: .nearby)
        return rows
    }

    func recents(limit: Int) async throws -> [RestaurantRowModel] {
        let rows = try await base.recents(limit: limit)
        provenance.recordRestaurantRows(rows, source: .recent)
        return rows
    }

    func search(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> [RestaurantRowModel] {
        let rows = try await base.search(query: query, origin: origin, sessionToken: sessionToken)
        provenance.recordSearchResults(rows)
        return rows
    }

    func resolve(
        _ row: RestaurantRowModel,
        sessionToken: PlacesSessionToken?
    ) async throws -> PickedRestaurant {
        let picked = try await base.resolve(row, sessionToken: sessionToken)
        provenance.recordRestaurantResolved(rowID: row.id)
        return picked
    }

    func addManual(name: String, city: String?, cuisine: String?) async throws -> PickedRestaurant {
        let picked = try await base.addManual(name: name, city: city, cuisine: cuisine)
        provenance.recordRestaurantAddedManually()
        return picked
    }
}

/// Pass-through dish search that notes which dishes were in "You've had here".
struct ProvenanceDishSearch: DishSearchProviding {
    let base: any DishSearchProviding
    let provenance: LogPickProvenance

    func history(restaurantID: UUID, limit: Int) async throws -> [DishRowModel] {
        let rows = try await base.history(restaurantID: restaurantID, limit: limit)
        provenance.recordHistoryDishes(rows)
        return rows
    }

    func menu(restaurantID: UUID, offset: Int, limit: Int) async throws -> DishListPage {
        try await base.menu(restaurantID: restaurantID, offset: offset, limit: limit)
    }

    func filterMenu(restaurantID: UUID, query: String, limit: Int) async throws -> [DishRowModel] {
        try await base.filterMenu(restaurantID: restaurantID, query: query, limit: limit)
    }

    func popular(offset: Int, limit: Int) async throws -> DishListPage {
        try await base.popular(offset: offset, limit: limit)
    }

    func searchAll(query: String, limit: Int) async throws -> [DishRowModel] {
        try await base.searchAll(query: query, limit: limit)
    }

    func resolveOrCreate(name: String, restaurantID: UUID) async throws -> PickedDish {
        let picked = try await base.resolveOrCreate(name: name, restaurantID: restaurantID)
        provenance.recordDishSelected(id: picked.id, wasCreated: picked.wasCreated)
        return picked
    }
}

import AteKit
import Foundation
import SwiftUI

/// State for the restaurant subject of ``SearchPicker`` (§11.1, §11.2, §11.5).
///
/// Two rules are structural here rather than incidental:
///  - **Results are never re-sorted.** `search()` assigns the server's array as-is. The blend's
///    ranking (strong manual matches → Places by distance → weak manual matches) is decided once,
///    server-side; a client sort would bury every manual row, which carries no distance.
///  - **Never flash to empty.** A new keystroke leaves the previous rows on screen and raises
///    `isSearching`; rows are replaced only when the new answer arrives.
@MainActor
@Observable
final class RestaurantPickerModel {
    private let services: SearchServices
    private let policy = SearchQueryPolicy(subject: .restaurants)

    /// One Places session per picker session, reused across keystrokes and **retired on resolve**.
    private var sessionToken = PlacesSessionToken()

    private(set) var nearby: [RestaurantRowModel] = []
    private(set) var recents: [RestaurantRowModel] = []
    /// The flat, server-ranked blend for the current query. `nil` = no query, show the defaults.
    private(set) var results: [RestaurantRowModel]?

    private(set) var isLoadingDefaults = false
    private(set) var isSearching = false
    private(set) var failure: SearchFailure?
    private(set) var resolvingRowID: String?
    private(set) var hasLoadedDefaults = false

    /// The query the create-fallback would create, or nil when it must not be offered (§11.2:
    /// only when the blend came back completely empty on a ≥2-char query, and never above results).
    private(set) var createQuery: String?
    private var createShownFor: String?

    /// Non-nil presents the §11.2 add-a-restaurant form.
    var addRestaurantRequest: AddRestaurantRequest?

    private var hasSentOpened = false

    init(services: SearchServices) {
        self.services = services
    }

    /// Fires `search_opened` exactly once per picker session. Not in `init` — SwiftUI may build a
    /// `@State` initial value more than once, and a funnel's first event must not be inflated.
    func markOpened(context: SearchContextName) {
        guard !hasSentOpened else { return }
        hasSentOpened = true
        services.telemetry.send(.opened(context: context, subject: .restaurants))
    }

    // MARK: - Defaults (empty query)

    func loadDefaults(origin: SearchOrigin?) async {
        guard !isLoadingDefaults else { return }
        isLoadingDefaults = true
        defer {
            isLoadingDefaults = false
            hasLoadedDefaults = true
        }

        // Recents work without location and without Places; nearby is best-effort on top. Running
        // them together means a denied-location user waits for one round-trip, not two.
        async let recentRows = loadRecents()
        async let nearbyRows = loadNearby(origin: origin)
        recents = await recentRows
        nearby = await nearbyRows
    }

    // MARK: - Search

    /// Debounced by the caller's `.task(id:)`; cancellation there is also the stale-response guard,
    /// so a slow answer for an abandoned query can never overwrite a newer one.
    func search(_ rawQuery: String, origin: SearchOrigin? = nil) async {
        guard let query = policy.query(from: rawQuery) else {
            results = nil
            createQuery = nil
            isSearching = false
            return
        }

        isSearching = true
        failure = nil
        let started = ContinuousClock.now
        defer { isSearching = false }

        do {
            // The origin is what earns predictions their `distance_meters`; without it the row
            // renders name + suburb only, which is correct, not broken.
            let rows = try await services.restaurants.search(
                query: query,
                origin: origin,
                sessionToken: sessionToken
            )
            guard !Task.isCancelled else { return }
            results = rows
            updateCreateFallback(query: query, resultCount: rows.count)
            services.telemetry.send(.query(
                subject: .restaurants,
                length: query.count,
                resultCount: rows.count,
                milliseconds: (ContinuousClock.now - started).wholeMilliseconds
            ))
            if rows.isEmpty {
                services.telemetry.send(.zeroResults(subject: .restaurants, queryLength: query.count))
            }
        } catch {
            guard !Task.isCancelled else { return }
            // §11.5/§6.2: keep whatever is on screen; the failure becomes an inline retry caption.
            failure = SearchFailure(error)
        }
    }

    private func updateCreateFallback(query: String, resultCount: Int) {
        // §11.2: only on a genuinely empty result set, and only as the last row.
        createQuery = resultCount == 0 ? query : nil
        guard let createQuery, createShownFor != createQuery else { return }
        createShownFor = createQuery
        services.telemetry.send(.createShown(subject: .restaurants))
    }

    // MARK: - Selection

    /// Resolves a tapped row. Returns nil when the resolve failed — the caller keeps the list up and
    /// shows the inline retry caption; a second tap while resolving is ignored (§11.5).
    func select(_ row: RestaurantRowModel, index: Int) async -> PickedRestaurant? {
        guard resolvingRowID == nil else { return nil }
        resolvingRowID = row.id
        defer { resolvingRowID = nil }

        do {
            let picked = try await services.restaurants.resolve(row, sessionToken: sessionToken)
            // The details call closed the Google session — the next keystroke starts a new one.
            sessionToken = PlacesSessionToken()
            services.telemetry.send(.resultSelected(
                subject: .restaurants,
                kind: row.telemetryKind,
                index: index
            ))
            return picked
        } catch {
            failure = SearchFailure(error)
            return nil
        }
    }

    // MARK: - Create fallback (§11.2)

    func addManual(name: String, suburb: String, cuisine: String) async -> PickedRestaurant? {
        do {
            let picked = try await services.restaurants.addManual(
                name: name,
                city: suburb.nilIfBlank ?? "",
                cuisine: cuisine.nilIfBlank
            )
            services.telemetry.send(.createUsed(subject: .restaurants))
            return picked
        } catch {
            failure = SearchFailure(error)
            return nil
        }
    }

    func clearFailure() {
        failure = nil
    }

    private func loadRecents() async -> [RestaurantRowModel] {
        do {
            return try await services.restaurants.recents(limit: 5)
        } catch {
            failure = SearchFailure(error)
            return []
        }
    }

    private func loadNearby(origin: SearchOrigin?) async -> [RestaurantRowModel] {
        guard let origin else { return [] }
        do {
            return try await services.restaurants.nearby(origin: origin)
        } catch {
            // A nearby failure is not worth a banner — Recents and search still work (§6.2).
            return []
        }
    }
}

extension String {
    /// `nil` rather than `""`, so an untouched optional form field stays absent server-side.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Duration {
    /// Whole milliseconds, for the `ms` telemetry parameter.
    var wholeMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

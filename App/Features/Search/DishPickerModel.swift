import AteKit
import Foundation
import SwiftUI

/// State for both dish subjects of ``SearchPicker`` (§11.3, §11.4, §11.5).
///
/// One model, two shapes: within a restaurant there are two default sections ("You've had here",
/// "On the menu") and a create-fallback; in the Search tab's global Dishes scope there is one
/// default section (most-reviewed) and, per §10, **no create-fallback at all** — you can't add a
/// dish without saying where it is.
@MainActor
@Observable
final class DishPickerModel {
    private let services: SearchServices
    private let subject: SearchSubject
    private let policy: SearchQueryPolicy

    /// §11.3 "You've had here" — empty in the global scope.
    private(set) var history: [DishRowModel] = []
    /// §11.3 "On the menu" (or the global "Most reviewed").
    private(set) var menu: [DishRowModel] = []
    private var menuNextOffset: Int?

    /// The flat filtered list. `nil` = no query, show the default sections.
    private(set) var results: [DishRowModel]?

    private(set) var isLoadingDefaults = false
    private(set) var isLoadingMore = false
    private(set) var isSearching = false
    private(set) var failure: SearchFailure?
    private(set) var isCreating = false
    private(set) var hasLoadedDefaults = false

    /// The name the "Add '<query>' as a new dish" row would create, or nil when it must not appear.
    private(set) var createQuery: String?
    private var createShownFor: String?

    private var hasSentOpened = false

    init(services: SearchServices, subject: SearchSubject) {
        self.services = services
        self.subject = subject
        self.policy = SearchQueryPolicy(subject: subject)
    }

    /// See ``RestaurantPickerModel/markOpened(context:)`` — once per picker session, not per body pass.
    func markOpened(context: SearchContextName) {
        guard !hasSentOpened else { return }
        hasSentOpened = true
        services.telemetry.send(.opened(context: context, subject: subject))
    }

    /// §11.3 KEYBOARD RULE: focus the field on appear **only** when there is nothing to show.
    /// Anything in either default section and the keyboard stays down — that's what keeps the
    /// happy path keyboard-free.
    var shouldAutoFocusSearchField: Bool {
        hasLoadedDefaults && history.isEmpty && menu.isEmpty
    }

    var offersCreateFallback: Bool {
        subject.restaurantID != nil
    }

    var canLoadMore: Bool {
        results == nil && menuNextOffset != nil
    }

    // MARK: - Defaults

    func loadDefaults() async {
        guard !isLoadingDefaults, !hasLoadedDefaults else { return }
        isLoadingDefaults = true
        defer {
            isLoadingDefaults = false
            hasLoadedDefaults = true
        }

        do {
            if let restaurantID = subject.restaurantID {
                async let historyRows = services.dishes.history(restaurantID: restaurantID, limit: 5)
                async let menuPage = services.dishes.menu(restaurantID: restaurantID, offset: 0, limit: 20)
                history = try await historyRows
                let page = try await menuPage
                menu = page.rows
                menuNextOffset = page.nextOffset
            } else {
                let page = try await services.dishes.popular(offset: 0, limit: 20)
                menu = page.rows
                menuNextOffset = page.nextOffset
            }
        } catch {
            failure = SearchFailure(error)
        }
    }

    /// §11.3: "On the menu" is paginated. Called from the last row's `.onAppear`.
    func loadMore() async {
        guard let offset = menuNextOffset, !isLoadingMore, results == nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = if let restaurantID = subject.restaurantID {
                try await services.dishes.menu(restaurantID: restaurantID, offset: offset, limit: 20)
            } else {
                try await services.dishes.popular(offset: offset, limit: 20)
            }
            menu += page.rows
            menuNextOffset = page.nextOffset
        } catch {
            failure = SearchFailure(error)
        }
    }

    // MARK: - Search

    func search(_ rawQuery: String) async {
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
            let catalogue: [DishRowModel]
            if let restaurantID = subject.restaurantID {
                catalogue = try await services.dishes.filterMenu(
                    restaurantID: restaurantID, query: query, limit: 20
                )
            } else {
                catalogue = try await services.dishes.searchAll(query: query, limit: 20)
            }
            guard !Task.isCancelled else { return }

            // §11.3: your-history matches lead, then the catalogue — one flat list, no duplicates.
            let matchedHistory = history.filter { $0.name.localizedCaseInsensitiveContains(query) }
            let rows = DishSearchRanking.flatten(history: matchedHistory, catalogue: catalogue)
            results = rows
            updateCreateFallback(query: query, rows: rows)

            services.telemetry.send(.query(
                subject: subject,
                length: query.count,
                resultCount: rows.count,
                milliseconds: (ContinuousClock.now - started).wholeMilliseconds
            ))
            if rows.isEmpty {
                services.telemetry.send(.zeroResults(subject: subject, queryLength: query.count))
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = SearchFailure(error)
        }
    }

    /// §11.4: the create row appears only when nothing here is case-insensitively equal to the
    /// query — near-duplicates are deliberately NOT blocked, and the row is never a top-level button.
    private func updateCreateFallback(query: String, rows: [DishRowModel]) {
        guard offersCreateFallback else {
            createQuery = nil
            return
        }
        createQuery = DishDedup.shouldOfferCreate(query: query, existingNames: rows.map(\.name))
            ? query
            : nil
        guard let createQuery, createShownFor != createQuery else { return }
        createShownFor = createQuery
        services.telemetry.send(.createShown(subject: subject))
    }

    // MARK: - Selection

    func select(_ row: DishRowModel, index: Int) -> PickedDish {
        services.telemetry.send(.resultSelected(
            subject: subject,
            kind: row.yourScore == nil ? "menu" : "history",
            index: index
        ))
        return PickedDish(id: row.dishID, name: row.name, restaurantID: row.restaurantID)
    }

    /// §11.4/§6.3: resolves inline (insert-or-return) with no form. An existing name silently
    /// becomes that dish — `wasCreated` is false and the fallback counter doesn't fire.
    func createDish(named name: String) async -> PickedDish? {
        guard let restaurantID = subject.restaurantID, !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let picked = try await services.dishes.resolveOrCreate(name: name, restaurantID: restaurantID)
            services.telemetry.send(.createUsed(subject: subject))
            if picked.wasCreated {
                services.telemetry.send(.dishCreateFallbackUsed(restaurantID: restaurantID))
            }
            return picked
        } catch {
            failure = SearchFailure(error)
            return nil
        }
    }

    // MARK: - Retry

    func retry() async {
        failure = nil
        hasLoadedDefaults = false
        await loadDefaults()
    }
}

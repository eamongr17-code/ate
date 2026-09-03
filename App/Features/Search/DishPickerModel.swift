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

    /// §6: the add row is **permanently visible**, so this is what it *does*, not whether it exists.
    private(set) var createRow: CreateRowState = .empty
    /// The last query for which the direct-create state was reported, so `create_shown` fires once
    /// per distinct query on the transition INTO that state — not on every keystroke that stays in it.
    private var createShownFor: String?

    /// Non-nil presents the §6 add-a-dish form.
    var addDishRequest: AddDishRequest?

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
            // No query — or one below the search threshold — is a *state* of the standing row now,
            // not its absence.
            updateCreateRow(rawQuery: rawQuery, rows: nil)
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
            updateCreateRow(rawQuery: query, rows: rows)

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

    /// §6 — supersedes §11.4's gate. The row is always there; this decides which of its three
    /// behaviours a tap gets, and reports the one that matters to the funnel.
    ///
    /// `rows == nil` means no filtered list exists yet (empty query, or one below the search
    /// threshold). Without a filtered list we can't claim "nothing here matches", so a typed name
    /// goes through the sheet rather than being minted on one tap.
    private func updateCreateRow(rawQuery: String, rows: [DishRowModel]?) {
        guard offersCreateFallback else {
            createRow = .empty
            return
        }
        let typed = policy.normalize(rawQuery)
        guard !typed.isEmpty else {
            createRow = .empty
            createShownFor = nil
            return
        }
        guard let rows else {
            createRow = .prefilled(name: typed, hasExactMatch: false)
            createShownFor = nil
            return
        }
        createRow = DishDedup.createRowState(query: typed, existingNames: rows.map(\.name))
        // §6: `create_shown` now means "one tap from here creates a dish", once per distinct query.
        guard createRow.isDirectCreate, createShownFor != typed else { return }
        createShownFor = typed
        services.telemetry.send(.createShown(subject: subject))
    }

    /// Every name currently on screen — what the Add sheet re-checks the edited name against, so its
    /// guard uses the same candidate set the row's state was decided from.
    var visibleNames: [String] {
        (results ?? (history + menu)).map(\.name)
    }

    /// The standing row was tapped, whatever state it was in — the denominator `create_used` never
    /// had. Fired before the work, so an abandoned sheet still counts as an attempt.
    func recordCreateRowTapped() {
        services.telemetry.send(.createRowTapped(
            subject: subject,
            hadQuery: createRow.hadQuery,
            mode: createRow.mode
        ))
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

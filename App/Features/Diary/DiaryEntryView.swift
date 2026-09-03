import AteKit
import SwiftUI

/// **Your journal entry** (§4) — one review of yours, as a page.
///
/// This is the screen the diary taps into, and the boundary the journal-first structure turns on:
/// everything here is *yours*. No aggregate, no review count, no one else's reviews (§2's three-marks
/// rule). "See all reviews of this dish" is the one, explicit crossing into everyone's page.
///
/// **Resolution is synchronous first.** The review is already on the diary's loaded page, so the
/// entry appears fully rendered with no spinner and no failure mode — the `@State` is seeded in
/// `init` from ``DetailContext/diaryEntry``. The async fetch exists only for the other door: an entry
/// reached from outside the diary (a deep link, a restored navigation path), where the screen has an
/// id and nothing else.
struct DiaryEntryView: View {
    let reviewID: UUID
    let context: DetailContext

    @Environment(\.openDish) private var openDish

    @State private var entry: FeedEntry?
    @State private var siblings: [FeedEntry]
    @State private var failure: String?
    @State private var isFetching = false
    @State private var hasRecordedView = false

    @MainActor
    init(reviewID: UUID, context: DetailContext) {
        self.reviewID = reviewID
        self.context = context
        _entry = State(initialValue: context.diaryEntry?(reviewID))
        _siblings = State(initialValue: context.diarySittingSiblings?(reviewID) ?? [])
    }

    var body: some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Color.backgroundRecessed)
            // The dish name is the title, and it is the name stored on YOUR review — a dish merged
            // away since you logged it does not rewrite your record (§4). Routes use the canonical id.
            .navigationTitle(entry?.dish.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .task { await resolveIfNeeded() }
            .onChange(of: entry?.id) { _, _ in recordViewedOnce() }
    }

    /// The synchronous path shows the entry with no loading state at all — the review is already on
    /// the diary's loaded page. The skeleton is for the other door (a deep link, a restored path),
    /// and it is the same 150/350 clock as everywhere else (§5).
    private var content: some View {
        resolvedContent
            .skeleton(isLoading: entry == nil && failure == nil, label: "Loading this entry") {
                DiaryEntrySkeleton()
            }
    }

    @ViewBuilder
    private var resolvedContent: some View {
        if let entry {
            entryList(entry)
        } else if let failure {
            List {
                DetailErrorView(message: failure) { await fetch() }
            }
        } else {
            Color.clear
        }
    }

    /// `.navigationSubtitle` rather than a date inside the list: the date is *what this page is*
    /// (§2 — date-as-structure belongs to the diary), not a field of the review.
    private var subtitle: String {
        guard let entry else { return "" }
        return entry.review.createdAt.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
        )
    }

    // MARK: - The page

    private func entryList(_ entry: FeedEntry) -> some View {
        List {
            // §1.1: exactly ONE card, alone on the recessed ground, and it is the subject of the
            // page. The row draws nothing — the card is the container.
            Section {
                DishCard(model: DishCardModel(entry), mode: .entry)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !siblings.isEmpty {
                sittingSection(entry)
            }

            onwardSection(entry)
        }
    }

    /// §4: the sitting is what makes a diary a record of *eating* rather than of dishes — one visit,
    /// several plates. Shown only when there is more than one, and never as a count or a score.
    private func sittingSection(_ entry: FeedEntry) -> some View {
        Section("Part of a sitting at \(entry.restaurant.name)") {
            ForEach(siblings) { sibling in
                NavigationLink(value: DiaryEntryRoute(reviewID: sibling.review.id)) {
                    DiaryEntrySiblingRow(entry: sibling)
                }
            }
        }
    }

    /// The three ways out. Deliberately flat rows in one section: the entry is a record, and the
    /// things you can do from it are all "go somewhere else", not actions on the review (V1 has no
    /// edit or delete path, so neither is offered).
    @ViewBuilder
    private func onwardSection(_ entry: FeedEntry) -> some View {
        Section {
            RestaurantNameLink(
                name: entry.restaurant.name,
                suburb: entry.restaurant.locality,
                restaurantID: entry.restaurant.id,
                from: .diaryEntry,
                style: .disclosureRow
            )

            seeAllReviewsRow(entry)

            if let onLogAgain = context.onLogAgain {
                Button("Log this again", systemImage: "plus.circle") {
                    context.analytics(DetailEvents.logCTATapped(from: .entryLogAgain))
                    onLogAgain(logAgainEntry(for: entry))
                }
                .foregroundStyle(Theme.Color.accent)
            }
        }
    }

    /// The mine/everyone's boundary, named out loud. It uses the *canonical* dish id, so a review of
    /// a since-merged dish lands on the survivor's page rather than a tombstone.
    @ViewBuilder
    private func seeAllReviewsRow(_ entry: FeedEntry) -> some View {
        let dishID = entry.dish.canonicalID
        if openDish.isWired {
            Button {
                context.analytics(DiaryEvents.diaryEntryDishOpened(dishID: dishID))
                openDish(dishID)
            } label: {
                LabeledDisclosureRow(title: "See all reviews of this dish")
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink("See all reviews of this dish", value: DishRoute(dishID: dishID))
        }
    }

    /// §4: "Log this again" opens the sheet pre-resolved — the canvas as root with one unrated card
    /// for this dish at this restaurant, which is exactly ``LogEntry/dish(restaurant:dishID:dishName:)``.
    private func logAgainEntry(for entry: FeedEntry) -> LogEntry {
        .dish(
            restaurant: SittingRestaurant(
                id: entry.restaurant.id,
                name: entry.restaurant.name,
                suburb: entry.restaurant.locality
            ),
            dishID: entry.dish.canonicalID,
            dishName: entry.dish.name
        )
    }

    // MARK: - Resolution

    private func resolveIfNeeded() async {
        guard entry == nil else {
            recordViewedOnce()
            return
        }
        await fetch()
    }

    private func fetch() async {
        guard let fetcher = context.entryFetcher, !isFetching else {
            if context.entryFetcher == nil { failure = "Couldn't open this entry." }
            return
        }
        isFetching = true
        failure = nil
        defer { isFetching = false }
        do {
            entry = try await fetcher.diaryEntry(reviewID: reviewID)
            recordViewedOnce()
        } catch is CancellationError {
            return
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// One short sentence about *this entry*, never the raw error — a PostgREST body is noise to the
    /// reader and Sentry already has it.
    private static func message(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline."
            default:
                return "Couldn't reach Ate. Check your connection."
            }
        }
        if (error as? AteAPIError) == .notAuthenticated { return "Sign in to see your diary." }
        return "Couldn't open this entry."
    }

    /// Once per appearance of a resolved entry, not once per body pass and not once per fetch
    /// attempt — a funnel's page-view must not be inflated by a retry.
    private func recordViewedOnce() {
        guard let entry, !hasRecordedView else { return }
        hasRecordedView = true
        context.analytics(DiaryEvents.diaryEntryViewed(
            reviewID: entry.review.id,
            dishID: entry.dish.canonicalID,
            isMultiDishSitting: !siblings.isEmpty
        ))
    }
}

// MARK: - Pieces

/// One other dish from the same sitting. The compact diary row shape (§3.3): thumbnail when there is
/// a photo, name, score — no byline, no place (you are already at it), no aggregate.
private struct DiaryEntrySiblingRow: View {
    let entry: FeedEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            // §3: always filled. A gutter that appears on some rows and not others is a ragged
            // list; the tile is the dish's identity, not a stand-in for a missing photo.
            DishTile(
                dish: DishTileSubject(
                    id: entry.dish.canonicalID,
                    name: entry.dish.name,
                    photoURL: entry.review.photoURL
                ),
                size: Theme.Size.thumbnail
            )
            Text(entry.dish.name)
                .font(Theme.Text.itemTitle)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Theme.Spacing.snug)
            // §4's RULE: `average` is for AGGREGATES. A single review's score is a half-step and
            // must read "3.0", never the bare "3" an aggregate formatter produces — a sibling row
            // that says 3 next to a card that says 3.0 looks like two different scores.
            Text(ScoreFormat.halfStep(entry.review.score.value))
                .font(Theme.Text.rowScore)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.hairline)
        .accessibilityElement(children: .combine)
    }
}

/// A `Button` that reads as a navigation row. Used where the row must *do* something before it
/// pushes (record the crossing into everyone's reviews) and so can't be a `NavigationLink`.
private struct LabeledDisclosureRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Spacing.snug) {
            Text(title)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer(minLength: Theme.Spacing.snug)
            Image(systemName: "chevron.forward")
                .font(Theme.Text.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.Color.textTertiary)
        }
        .contentShape(.rect)
    }
}

#if DEBUG
#Preview("Entry — multi-dish sitting") {
    let entries = FeedPlaceholder.entries(count: 3)
    NavigationStack {
        DiaryEntryView(
            reviewID: entries[0].review.id,
            context: DetailContext(
                dataSource: PreviewDetailDataSource(),
                analytics: DetailTelemetry.none,
                diaryEntry: { id in entries.first { $0.review.id == id } },
                diarySittingSiblings: { id in entries.filter { $0.review.id != id } },
                onLogAgain: { _ in }
            )
        )
    }
}
#endif

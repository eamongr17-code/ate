import AteKit
import SwiftUI

/// **`Dish`** — one dish, everything anybody has said about it, and the one thing you can do:
/// save it.
///
/// In the order `Dish.dc.html` sets them down: a tilted pair of photos, the name at 38, the place
/// as a link under it, the aggregate at 64 with its stars, how many people and the dish's dietary
/// chips, then the reviews — **You first**, then everyone else newest first.
///
/// Round 4 (Eamon's notes on build 79): a review is who and how much — avatar, handle, score, no
/// words; the row opens their entry and the avatar or handle opens them. The page sits on the list
/// gutter (12, the Journal's), and it arrives whole: a still skeleton of the full layout until the
/// header and the first reviews are both in, then one fade.
///
/// The bookmark in the top bar is the *same* save the feed's dish rows make: one ``SaveAction``,
/// one broadcast, so a dish saved here is already saved on the feed underneath (AGENTS.md rule 2).
struct DishScreen: View {
    let store: DishPageStore
    var onPlace: (UUID) -> Void = { _ in }
    var onReview: (DishReview) -> Void = { _ in }
    /// The avatar or handle on a review: that person's profile.
    var onProfile: (UUID) -> Void = { _ in }
    var onSave: (DishSummary) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    /// The shared full-screen viewer (browse lane, round 3): a hero photo opens it, swipeable.
    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                switch store.isSettled ? store.header : .loading {
                case .loading:
                    VStack(alignment: .leading, spacing: AteMetrics.loose) {
                        DishHeaderSkeleton()
                        ReviewSkeleton()
                    }
                    .padding(.horizontal, AteMetrics.listGutter)
                    .transition(.opacity)
                case .unavailable:
                    AteEmptyState(title: "This dish\nisn't here.")
                        .ateEmptyPlacement(top: AteDetailPage.contentTop)
                case .unreachable:
                    // The read never came back — not the same as a dish that is gone, and worth
                    // another try.
                    AteUnreachableState { Task { await store.retry() } }
                        .ateEmptyPlacement(top: AteDetailPage.contentTop)
                    .accessibilityIdentifier("dish.unreachable")
                case .ready(let summary):
                    VStack(alignment: .leading, spacing: AteMetrics.loose) {
                        hero
                        title(summary)
                        aggregate(summary)
                        reviews
                    }
                    .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .refreshable { await store.refresh() }
        .task { await store.load() }
    }

    // MARK: - Bands

    /// `padding:60px 12px 0; justify-content:space-between` — back, and the bookmark. Icons only;
    /// the design puts labels nowhere near this row (rule 1).
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            if let summary = store.summary {
                AteIconButton(
                    icon: store.isSaved ? .saved : .save,
                    label: store.isSaved ? "Saved \(summary.name)" : "Save \(summary.name)",
                    size: 23
                ) {
                    onSave(summary)
                }
                .accessibilityAddTraits(store.isSaved ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("dish.save")
            }
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    /// `padding:6px 0 0 8px` — two 150pt squircles, tilted and lapped 44. Design rule 6: photos
    /// tilt only in small static clusters, and this is the largest one in the app.
    ///
    /// Absent entirely when the dish has no photo. A grey placeholder here would be a picture of
    /// nothing at the top of the page, which is worse than starting on the name.
    @ViewBuilder
    private var hero: some View {
        let photos = store.heroPhotoURLs.map { AtePhoto.remote($0) }
        if photos.isEmpty == false {
            PhotoCluster(
                photos: photos,
                side: Self.heroPhoto,
                topPadding: 6,
                bottomPadding: 0,
                overlap: Self.heroOverlap,
                angles: AtePhotoAngles.dishHero,
                onTap: { showPhotos(photos, at: $0) }
            )
            // The cluster already insets 6 for its own tilt; the artboard's is 8 past the gutter.
            .padding(.leading, AteMetrics.listGutter - 6 + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let heroPhoto: CGFloat = 150
    /// The place link is drawn 32 tall under the dish; a finger gets 44.
    private static let placeLinkHeight: CGFloat = 32
    private static let placeLinkHit = AteHitOutset(height: placeLinkHeight)
    private static let heroOverlap: CGFloat = 44

    /// The dish at 38, and the place under it as the door back to the menu it came off.
    private func title(_ summary: DishSummary) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            AteExactText(text: summary.name, style: .entryPlace, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button {
                onPlace(summary.restaurantID)
            } label: {
                HStack(spacing: 2) {
                    Text(summary.restaurantName).ateText(.rowTitle)
                    AteIcon.chevron.view(size: 15)
                }
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(minHeight: Self.placeLinkHeight)
                .ateHitArea(Self.placeLinkHit)
            }
            .buttonStyle(.plain)
            .ateHitFootprint(Self.placeLinkHit)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary.restaurantName)
            .accessibilityIdentifier("dish.place")
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    /// `gap:14px` — the number at 64, and beside it the star row and how many people.
    ///
    /// An unrated dish prints neither: design rule 7 says a score is never inferred, so there is no
    /// "0.0", no row of grey stars and no mark — the score slot is simply empty.
    ///
    /// The dish's dietary chips (round 4; the artboard predates tags) ride on the people line — the
    /// line nearest both the name and the score: the consensus of what people tagged it.
    private func aggregate(_ summary: DishSummary) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let score = summary.score {
                // Fixed digits: the secret 6.0 is exactly as wide as any 5.
                Text(ScoreFormat.average(score))
                    .ateText(.dishScore)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel("Rated \(ScoreFormat.average(score))")
                VStack(alignment: .leading, spacing: 6) {
                    starRow(for: score)
                    meta(summary)
                }
            } else {
                meta(summary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    /// How many people, then the chips. Either can be absent; both absent is no line at all.
    @ViewBuilder
    private func meta(_ summary: DishSummary) -> some View {
        if summary.peopleCount > 0 || summary.tags.isEmpty == false {
            AteFlow(spacing: AteMetrics.snug) {
                people(summary)
                if summary.tags.isEmpty == false {
                    DietTagChips(tags: summary.tags, fill: AtePalette.automatic.field)
                        .accessibilityIdentifier("dish.tags")
                }
            }
        }
    }

    /// Five 20pt stars, filled by the fraction the average earns — whole, half, or empty, all at
    /// full strength.
    private func starRow(for score: Double) -> some View {
        let stars = ScoreFormat.stars(for: score)
        return HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                AteStar(fill: fill(index: index, full: stars.full, half: stars.half), side: 20, lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(index: Int, full: Int, half: Bool) -> Double {
        if index < full { return 1 }
        if index == full, half { return 0.5 }
        return 0
    }

    @ViewBuilder
    private func people(_ summary: DishSummary) -> some View {
        if summary.peopleCount > 0 {
            HStack(spacing: AteMetrics.tight) {
                AteIcon.feed.view(size: 14)
                Text(summary.peopleCount == 1 ? "1 person" : "\(summary.peopleCount) people")
                    .ateText(.meta)
            }
            .foregroundStyle(AtePalette.automatic.muted)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var reviews: some View {
        switch store.phase {
        case .loading:
            ReviewSkeleton()
                .padding(.horizontal, AteMetrics.gutter)
        case .empty:
            // Nobody has written about it yet. Honest, and not an instruction.
            AteEmptyState(title: "Nobody's written\nabout this yet.")
        case .signedOut:
            AteEmptyState(title: "Nobody's\nsigned in.")
        case .failed(let message):
            AteEmptyState(title: message)
        case .ready:
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.reviews) { review in
                    DishReviewRow(
                        review: review,
                        onOpen: { onReview(review) },
                        onProfile: review.author.map { author in { onProfile(author.id) } }
                    )
                    .task { await store.loadMoreIfNeeded(after: review) }
                }
                if let message = store.inlineErrorMessage {
                    Text(message)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, AteMetrics.regular)
                }
            }
            .padding(.horizontal, AteMetrics.listGutter)
        }
    }
}

/// **One review: who, and how much** (round 4) — a 36pt avatar, the handle, and their score as the
/// butter pill at the right. No words: the words are one tap away, in the entry.
///
/// Two doors, side by side rather than nested (a button inside a button's label is never heard):
/// the avatar and handle open **the person**, the rest of the row opens **the visit** it came out
/// of. A legacy review carries no `entry_id` (0018) and a blocked or deleted author no name — that
/// half is simply not a control then, because a control that goes nowhere is worse than none.
struct DishReviewRow: View {
    let review: DishReview
    let onOpen: () -> Void
    var onProfile: (() -> Void)?

    /// `padding:14px 0` around a 36pt avatar, `gap:12px`.
    private static let avatar: CGFloat = 36
    private static let padding: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            AteHairline()
            HStack(spacing: 0) {
                person
                visit
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(review.isMine ? "dish.review.mine" : "dish.review")
    }

    @ViewBuilder
    private var person: some View {
        let label = HStack(spacing: AteMetrics.regular) {
            AteAvatar(
                userID: review.author?.id ?? review.reviewID,
                handle: handle,
                side: Self.avatar,
                textStyle: .avatarInitialMedium
            )
            Text(name)
                .ateText(.controlSmall)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, Self.padding)
        .padding(.trailing, AteMetrics.regular)
        .contentShape(.rect)
        if let onProfile {
            Button(action: onProfile) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dish.review.person")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var visit: some View {
        let label = HStack(spacing: 0) {
            Spacer(minLength: 0)
            score
        }
        .frame(maxWidth: .infinity, minHeight: Self.avatar + Self.padding * 2)
        .contentShape(.rect)
        if review.entryID == nil {
            label
        } else {
            Button(action: onOpen) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(scoreLabel)
                .accessibilityIdentifier("dish.review.entry")
        }
    }

    /// "You" for your own, the handle for everybody else's. A missing author is blocked or gone —
    /// the review still stands, it just loses its name (contract).
    private var name: String {
        if review.isMine { return "You" }
        guard let username = review.author?.username else { return "Someone" }
        return "@\(username)"
    }

    private var handle: String { review.author?.username ?? "?" }

    private var scoreLabel: String {
        review.score.map { "\(name), \(ScoreFormat.halfStep($0.value))" } ?? name
    }

    /// Design rule 7: an unrated review leaves the score slot empty — no number, no zero, no mark.
    @ViewBuilder
    private var score: some View {
        if let score = review.score {
            ScoreToken(rating: score, prose: 16)
        }
    }
}

/// The header before it has arrived — the shape of a dish, not a spinner.
private struct DishHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 150, height: 150)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 240, height: 36)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 96, height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// …and the reviews, drawn as the rows they are waiting for.
private struct ReviewSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        Circle()
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 36, height: 36)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 88, height: 12)
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 46, height: 20)
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

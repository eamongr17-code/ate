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
    /// "More to explore" and "More like this", under the reviews (round 7). `nil` for a signed-out
    /// browser: they are signed-in reads, and a section that could never load is not held open.
    var explore: DishExploreStore?
    var onTag: (DishTag) -> Void = { _ in }
    var onSimilar: (SimilarDish, Int) -> Void = { _, _ in }
    var onPlace: (UUID) -> Void = { _ in }
    var onReview: (DishReview) -> Void = { _ in }
    /// The avatar or handle on a review: that person's profile.
    var onProfile: (UUID) -> Void = { _ in }
    var onSave: (DishSummary) -> Void = { _ in }

    /// The shared full-screen viewer (browse lane, round 3): a hero photo opens it, swipeable.
    @Environment(\.atePhotoViewer) private var showPhotos
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            // One lazy stack, and every review is one of its own rows — never a `LazyVStack` of
            // reviews inside a `VStack` under the header, the shape that locked the Feed's main
            // thread for minutes (`FeedScreen`).
            LazyVStack(alignment: .leading, spacing: 0) {
                if let preview = store.preview, store.isSettled == false || store.summary != nil {
                    previewedPage(preview)
                } else {
                    page
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        // The system back button, and the bookmark in glass beside it (round 4).
        .ateNavigationBar(trailing: { saveButton })
        .refreshable {
            await store.refresh()
            await explore?.refresh()
        }
        .task {
            await store.load()
            // After the page's own read, never beside it: the sections below the reviews must not
            // slow the part of the page somebody opened it for.
            guard store.summary != nil else { return }
            await explore?.load()
        }
        #if DEBUG
        .onAppear { DetailTimings.opened("dish", hasPreview: store.preview != nil) }
        .onChange(of: store.isSettled) { _, settled in if settled { DetailTimings.settled("dish") } }
        #endif
    }

    /// Opened by id alone: a still skeleton of the whole page, then the page once, together.
    @ViewBuilder
    private var page: some View {
        switch store.isSettled ? store.header : .loading {
        case .loading:
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                DishHeaderSkeleton()
                ReviewSkeleton()
            }
            .padding(.horizontal, AteMetrics.listGutter)
            .transition(.opacity)
        case .unavailable:
            LegacyEmptyState(title: "This dish\nisn't here.")
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
                title(name: summary.name, place: summary.restaurantName, placeID: summary.restaurantID)
                aggregate(summary)
            }
            .transition(.opacity)
            // The reviews are rows of this stack, not a band inside the header's; each case
            // puts the header's `loose` gap above its first row itself.
            reviews
                .transition(.opacity)
            exploreSections
        }
    }

    /// Under the reviews, once the page has settled on a dish (round 7).
    @ViewBuilder
    private var exploreSections: some View {
        if let explore, store.isSettled, store.summary != nil {
            DishExploreSections(store: explore, onTag: onTag, onDish: onSimilar)
                .transition(.opacity)
        }
    }

    // MARK: - Bands

    @ViewBuilder
    private var saveButton: some View {
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

    /// The dish at 38, and the place under it as the door back to the menu it came off. Before the
    /// read, a place the opening row did not know is a still bar at the link's own height.
    private func title(name: String, place: String?, placeID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            AteExactText(text: name, style: .entryPlace, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let place {
                Button {
                    guard let placeID else { return }
                    PlacePreviews.shared.note(placeID, name: place)
                    onPlace(placeID)
                } label: {
                    HStack(spacing: 2) {
                        Text(place).ateText(.rowTitle)
                        AteIcon.chevron.view(size: 15)
                    }
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(minHeight: Self.placeLinkHeight)
                    .ateHitArea(Self.placeLinkHit)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(Self.placeLinkHit)
                .disabled(placeID == nil)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(place)
                .accessibilityIdentifier("dish.place")
            } else {
                AteSkeletonBar(width: 110, height: 14, palette: .automatic)
                    .frame(height: Self.placeLinkHeight)
            }
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
            // On the list gutter, where the rows it stands for will be.
            ReviewSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, AteMetrics.loose)
        case .empty:
            // Nobody has written about it yet. Honest, and not an instruction.
            LegacyEmptyState(title: "Nobody's written\nabout this yet.")
                .padding(.top, AteMetrics.loose)
        case .signedOut:
            LegacyEmptyState(title: "Nobody's\nsigned in.")
                .padding(.top, AteMetrics.loose)
        case .failed(let message):
            LegacyEmptyState(title: message)
                .padding(.top, AteMetrics.loose)
        case .ready:
            reviewRows
        }
    }

    /// The reviews, one row each of the page's lazy stack (see `body`), touching — the rows carry
    /// their own hairline — with the header's `loose` gap above the first.
    @ViewBuilder
    private var reviewRows: some View {
        if store.reviews.isEmpty, store.inlineErrorMessage == nil {
            // What the list's own (empty) stack used to hold: the gap above it, and nothing.
            Color.clear.frame(height: 0).padding(.top, AteMetrics.loose)
        }
        ForEach(store.reviews) { review in
            DishReviewRow(
                review: review,
                onOpen: { onReview(review) },
                // Your own "You" is not a door, exactly as on a place's visits: the You
                // tab is your profile. The row still opens your entry.
                onProfile: review.isMine ? nil : review.author.map { author in { onProfile(author.id) } }
            )
            .task { await store.loadMoreIfNeeded(after: review) }
            .padding(.top, review.id == store.reviews.first?.id ? AteMetrics.loose : 0)
            .padding(.horizontal, AteMetrics.listGutter)
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.regular)
                .padding(.top, store.reviews.isEmpty ? AteMetrics.loose : 0)
                .padding(.horizontal, AteMetrics.listGutter)
        }
    }
}

// MARK: - Before the read (round 6)

extension DishScreen {
    /// **Opened from a row that knew the dish** (round 6): one header, drawn at once from the preview
    /// and filled in place as the reads answer — the same views throughout, so the name never
    /// re-draws and anything that does move (a hero the row could not know about) glides, never
    /// pops. The reviews wait as still rows at their own size.
    @ViewBuilder
    private func previewedPage(_ preview: DishPreview) -> some View {
        let summary = store.isSettled ? store.summary : nil
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            if summary != nil {
                hero
            } else {
                previewHero(preview)
            }
            title(
                name: summary?.name ?? preview.name,
                place: summary?.restaurantName ?? preview.restaurantName,
                placeID: summary?.restaurantID ?? preview.restaurantID
            )
            if let summary {
                aggregate(summary)
            } else {
                previewAggregate(preview)
            }
        }
        if summary != nil {
            reviews
                .transition(.opacity)
            exploreSections
        } else {
            ReviewSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, AteMetrics.loose)
                .transition(.opacity)
        }
    }

    /// The hero as the opening row knew it: its photo (the read may add the second), a still
    /// squircle when it knew there are photos but not which, and nothing when it could not tell —
    /// a hero that then arrives glides the page down rather than popping in.
    @ViewBuilder
    private func previewHero(_ preview: DishPreview) -> some View {
        if let url = preview.photoURL {
            PhotoCluster(
                photos: [AtePhoto.remote(url)],
                side: Self.heroPhoto,
                topPadding: 6,
                bottomPadding: 0,
                overlap: Self.heroOverlap,
                angles: AtePhotoAngles.dishHero
            )
            .padding(.leading, AteMetrics.listGutter - 6 + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if preview.hasPhotos == true {
            RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: Self.heroPhoto), style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: Self.heroPhoto, height: Self.heroPhoto)
                .padding(.top, 6)
                .padding(.leading, AteMetrics.listGutter + 2)
                .accessibilityHidden(true)
        }
    }

    /// The aggregate as the opening row printed it — or its shape, still, until the read answers.
    private func previewAggregate(_ preview: DishPreview) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let score = preview.score {
                Text(ScoreFormat.average(score))
                    .ateText(.dishScore)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel("Rated \(ScoreFormat.average(score))")
                VStack(alignment: .leading, spacing: 6) {
                    starRow(for: score)
                    AteSkeletonBar(width: 72, height: 12, palette: .automatic)
                }
            } else {
                // The number's own box at 64, and the stars' row and the people line beside it.
                AteSkeletonBar(width: 96, height: 52, palette: .automatic)
                    .frame(height: AteTextStyle.dishScore.lineBox(dynamicTypeSize))
                VStack(alignment: .leading, spacing: 6) {
                    AteSkeletonBar(width: 108, height: 18, palette: .automatic)
                    AteSkeletonBar(width: 72, height: 12, palette: .automatic)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .accessibilityHidden(preview.score == nil)
    }
}

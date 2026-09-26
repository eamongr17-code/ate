import AteKit
import SwiftUI

/// Where an entry is opened from.
struct EntryRoute: Hashable, Identifiable {
    let entryID: UUID

    var id: UUID { entryID }
}

/// **`Entry`** — the whole entry, on one page.
///
/// A single piece of white paper laid on the linen ground: 24pt top corners, 16 clear either side,
/// and it runs off the bottom of the screen rather than stopping on it (design rule 10). On it, in
/// the card's own order (`EntryHier.dc.html`, 2026-09-26): **the dish rows**, the person's words
/// with their tokens, the tilted photo collage, and the place line — pin, place, suburb, and the day
/// at the right. The restaurant is not the title and there is no bill: the dish is the item.
///
/// There is no receipt here. The receipt is the artefact Ate prints for **sharing** — the Summary
/// and Share screens — and the page a person reads their own entry on is a page, not a printout.
///
/// Everything on it is still a correction: the place line opens ``PlaceSheet`` and a dish row
/// ``DishSheet`` (`entry_corrected`), one gesture away from opening their pages, because the
/// structure is Ate's guess and the person has the last word on it.
struct EntryScreen: View {
    let route: EntryRoute
    let services: AteServices
    /// Called whenever the entry changes, so the journal — or the feed — behind this screen stays true.
    var onChange: (EntryCard) -> Void = { _ in }
    /// The pencil: reopen these words in the composer. Your own entries only.
    var onEdit: (EntryCard) -> Void = { _ in }
    /// The byline on somebody else's entry.
    var onProfile: (UUID) -> Void = { _ in }
    /// The place at the head of the page, and a bill line — the same two destinations a slip's pin
    /// and its dish rows open.
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    /// This entry's author was blocked from its actions sheet: every list behind this page is stale.
    var onBlocked: () -> Void = {}

    @State private var model: EntryModel
    @State private var isShowingActions = false
    #if DEBUG || BETA
    /// The one genuinely uncertain interaction on this page, shipped as both answers
    /// (``AteVariants``). Held as state so flipping it redraws the page under the menu.
    @State private var variants = AteVariants.shared
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.atePhotoViewer) private var showPhotos

    init(
        route: EntryRoute,
        services: AteServices,
        saves: SaveAction,
        onChange: @escaping (EntryCard) -> Void = { _ in },
        onEdit: @escaping (EntryCard) -> Void = { _ in },
        onProfile: @escaping (UUID) -> Void = { _ in },
        onPlace: @escaping (UUID) -> Void = { _ in },
        onDish: @escaping (UUID) -> Void = { _ in },
        onBlocked: @escaping () -> Void = {}
    ) {
        self.route = route
        self.services = services
        self.onChange = onChange
        self.onEdit = onEdit
        self.onProfile = onProfile
        self.onPlace = onPlace
        self.onDish = onDish
        self.onBlocked = onBlocked
        _model = State(initialValue: EntryModel(route: route, services: services, saves: saves))
    }

    var body: some View {
        ScrollView {
            if let failure = model.loadFailure {
                failed(failure)
            } else {
                page
                    .padding(.horizontal, AteMetrics.pageInset)
                    .padding(.top, AteMetrics.pageGap)
            }
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .task {
            services.savedDishes.add(model)
            await model.load()
        }
        .onChange(of: model.card) { _, card in
            if let card { onChange(card) }
        }
        .sheet(isPresented: $model.isCorrectingPlace) { placeSheet }
        .sheet(item: $model.correcting) { correcting in dishSheet(correcting.item) }
        .sheet(isPresented: $isShowingActions) { actionsSheet }
        .confirmationDialog("Delete this entry?", isPresented: $model.isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete() { dismiss() }
                }
            }
        }
        .alert("Couldn't reach Ate.", isPresented: $model.deleteFailed) {
            Button("OK", role: .cancel) {}
        }
        // `Share.dc.html` — the coral screen, and the only place a receipt leaves from. The same
        // card the actions sheet's Share row presents, so the artefact is identical either way.
        .fullScreenCover(item: $model.sharing) { sharing in
            ShareScreen(
                artefact: sharing.artefact,
                source: .entry,
                analytics: services.analytics
            )
        }
    }

    // MARK: - Failure

    /// The page could not be drawn. Two different answers (``LoadFailure``): the phone or the
    /// server let us down — say so, and offer the retry — or the entry itself is gone, deleted or
    /// its author blocked, where a retry would be a button that never works. Either way the state
    /// sits on the ground on the line every empty state shares, and Back is still in the top bar.
    @ViewBuilder
    private func failed(_ failure: LoadFailure) -> some View {
        Group {
            switch failure {
            case .unreachable:
                AteUnreachableState { Task { await model.retryLoad() } }
            case .gone:
                AteEmptyState(title: "This entry\nis gone.")
                    .accessibilityIdentifier("entry.gone")
            }
        }
        .ateEmptyPlacement(top: AteMetrics.contentTop + AteMetrics.hit)
    }

    // MARK: - The page

    /// `.slip`: `padding:8px 20px 0`, `gap:16px`, `border-radius:24px 24px 0 0`, `min-height:760`.
    private var page: some View {
        VStack(alignment: .leading, spacing: AteMetrics.pageBandGap) {
            if let card = model.card {
                dishes(card)
                words
                photos
                placeLine(card)
            }
        }
        .padding(.top, AteMetrics.pagePaddingTop)
        .padding(.horizontal, AteMetrics.pagePaddingSide)
        // The artboard has no bottom padding — its page simply continues past the screen. Ours can be
        // scrolled to the end, and a place line sitting on the cut edge would read as a crop.
        .padding(.bottom, AteMetrics.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: pageMinimumHeight, alignment: .top)
        .ateSlip()
        .background(AteColor.slip, in: UnevenRoundedRectangle(
            topLeadingRadius: AteMetrics.pageTop,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: AteMetrics.pageTop,
            style: .continuous
        ))
    }

    /// **The dish rows lead** — or, until the sorter has answered, their shape.
    @ViewBuilder
    private func dishes(_ card: EntryCard) -> some View {
        switch model.state {
        case .printed:
            if model.dishes.isEmpty == false {
                // Your own rows are corrections; somebody else's are bookmarks.
                EntryDishRows(
                    dishes: model.dishes,
                    onOpen: { onDish($0.dishID) },
                    onCorrect: card.isMine ? { dish in model.correct(dish) } : nil,
                    onSave: card.isMine ? nil : { dish in Task { await model.toggleSave(dish: dish) } },
                    tapOpensDetail: tapOpensDetail
                )
            }
        case .pending, .failed:
            EntryPendingDishes(isFailed: model.state == .failed) {
                Task { await model.retrySort() }
            }
        }
    }

    /// **The place line** — pin, place, suburb, and the day. Its tap is the same open question the
    /// dish rows carry (``AteVariants/entryTapOpensDetail``): the place's own page, or
    /// ``PlaceSheet`` to change it — the other is always one long press away. Somebody else's entry
    /// has no correction, so its line always opens the page. A place never attached is not guessed
    /// at (design rule 8): the line carries only the day, and on your own entry it attaches one.
    private func placeLine(_ card: EntryCard) -> some View {
        let openPage: (() -> Void)? = card.place.map { place in { onPlace(place.id) } }
        let correct: (() -> Void)? = card.isMine ? { model.isCorrectingPlace = true } : nil
        let primary = tapOpensDetail ? (openPage ?? correct) : (correct ?? openPage)
        let secondary: (title: String, action: () -> Void)? = if tapOpensDetail {
            openPage == nil ? nil : correct.map { (title: "Change the place", action: $0) }
        } else {
            correct == nil ? nil : openPage.map { (title: "Open \(card.place?.name ?? "")", action: $0) }
        }
        return EntryPlaceLine(
            place: card.place?.name,
            suburb: card.place?.suburb,
            day: RelativeAge.day(card.createdAt),
            action: primary,
            secondary: secondary
        ) {
            variantSwitch
        }
    }

    /// Which gesture owns a tap on the place line and on a dish row. Always `true` in a Release
    /// build: the variant machinery does not exist there, and the default is the one that ships.
    private var tapOpensDetail: Bool {
        #if DEBUG || BETA
        variants.entryTapOpensDetail
        #else
        true
        #endif
    }

    /// The toggle itself, in the menu it is about — the gallery carries the same switch, but the
    /// gallery is not reachable from a TestFlight build and this page is. Debug and Beta only.
    @ViewBuilder
    private var variantSwitch: some View {
        #if DEBUG || BETA
        Button(variants.entryTapSwitchTitle) {
            variants.entryTapOpensDetail.toggle()
        }
        #endif
    }

    @ViewBuilder
    private var photos: some View {
        if model.photos.isEmpty == false {
            PhotoCollage(
                photos: model.photos,
                width: contentWidth,
                surface: AteColor.slip
            ) { index in
                showPhotos(model.photos, at: index)
            }
        }
    }

    /// The person's own words, with their score pills and tag chips still in them. `.prose` at 17 —
    /// the biggest the words are anywhere outside the composer. A place they named is plain text.
    @ViewBuilder
    private var words: some View {
        if model.composition.plain.isEmpty == false {
            // A score pill is a link to its dish, exactly as a dish row is.
            InlineTokenText(composition: model.composition, style: .proseLarge, onScoreDish: onDish)
                .accessibilityIdentifier("entry.words")
        }
    }

    // MARK: - Measurements

    /// The page's content width — what the collage is laid out against. Arithmetic, not geometry: the
    /// page is inset by a fixed amount from a screen whose width is known.
    private var contentWidth: CGFloat {
        AteScreen.width - 2 * AteMetrics.pageInset - 2 * AteMetrics.pagePaddingSide
    }

    /// The artboard's `min-height:760`: everything left of the screen under the top bar, plus the 28
    /// the page always runs past the fold.
    private var pageMinimumHeight: CGFloat {
        let top = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.pageGap
        return max(0, AteScreen.height - top + AteMetrics.pageOvershoot)
    }

    // MARK: - Bands

    /// Back / edit / share, exactly as `Entry.dc.html` sets them down — there is no visibility control,
    /// because public/private no longer exists. Icons only — the design puts labels nowhere near this
    /// row (rule 1).
    ///
    /// Somebody else's entry swaps the two controls that only an author can use for the two a reader
    /// needs: the byline that says whose visit this was, and the bookmark that puts it on their shelf
    /// (`docs/DESIGN.md`, "Not drawn").
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            if let byline = model.byline {
                bylineButton(byline)
            }
            Spacer(minLength: AteMetrics.snug)
            if let card = model.card {
                if card.isMine {
                    authorControls(card)
                } else {
                    readerControls(card)
                }
            }
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    private func bylineButton(_ byline: AteByline) -> some View {
        Button {
            onProfile(byline.userID)
        } label: {
            HStack(spacing: AteMetrics.snug) {
                AteAvatar(userID: byline.userID, handle: byline.handle)
                // A long handle truncates (`.trunc`); the age beside it never does.
                Text(verbatim: "@\(byline.handle)")
                    .ateText(.controlSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(byline.age)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .frame(minHeight: AteMetrics.hit)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("@\(byline.handle), \(byline.age)")
        .accessibilityIdentifier("entry.byline")
    }

    private func authorControls(_ card: EntryCard) -> some View {
        Group {
            AteIconButton(icon: .edit, label: "Edit", size: 21) { onEdit(card) }
            AteIconButton(icon: .share, label: "Share receipt", size: 22) { model.share() }
                .disabled(model.receipt == nil)
                .opacity(model.receipt == nil ? 0.35 : 1)
            authorMenu
        }
        .fixedSize()
    }

    /// The "…" on your own entry — the same mark somebody else's entry carries, opening the
    /// system's own menu. Delete is the one thing in it, and it asks before it goes.
    private var authorMenu: some View {
        Menu {
            Button("Delete", role: .destructive) { model.isConfirmingDelete = true }
                .accessibilityIdentifier("entry.delete")
        } label: {
            AteIcon.more.view(size: 22)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .foregroundStyle(AtePalette.automatic.fg)
        .accessibilityLabel("More")
        .accessibilityIdentifier("entry.more")
    }

    /// The whole visit, at once — and the "…" that carries share, report and block. Disabled while
    /// there is no bill, because there is nothing to save until the receipt has printed.
    private func readerControls(_ card: EntryCard) -> some View {
        Group {
            AteIconButton(
                icon: model.isEveryDishSaved ? .saved : .save,
                label: model.isEveryDishSaved ? "Saved every dish" : "Save every dish",
                size: 22
            ) {
                Task { await model.toggleSaveEveryDish() }
            }
            .disabled(card.items.isEmpty)
            .opacity(card.items.isEmpty ? 0.35 : 1)
            .accessibilityIdentifier("entry.saveAll")
            // The actions sheet is entirely about a person — save their place, share their visit,
            // report it, block them. With no author on the row (blocked, deleted) there is nobody
            // to act on, so the control is absent rather than opening an empty sheet.
            if model.byline != nil {
                AteIconButton(icon: .more, label: "More", size: 22) { isShowingActions = true }
            }
        }
        .fixedSize()
    }

    // MARK: - Sheets

    /// The place. The *same* sheet the composer's Place key opens — the same action has to work
    /// identically everywhere it appears.
    private var placeSheet: some View {
        PlaceSheet(
            directory: services.places,
            initialQuery: model.card?.place?.name ?? "",
            selected: model.card?.restaurantID
        ) { place in
            Task { await model.correctPlace(place) }
        }
    }

    private func dishSheet(_ item: AteReceipt.Item) -> some View {
        DishSheet(
            directory: services.places,
            placeID: model.card?.restaurantID,
            placeName: model.card?.place?.name,
            item: item
        ) { dishID, dishName in
            Task { await model.correctDish(reviewID: item.id, dishID: dishID, dishName: dishName) }
        }
    }

    /// The same sheet a profile's "…" opens — save this place, share, report, block — pointed at
    /// this visit and its author.
    @ViewBuilder
    private var actionsSheet: some View {
        if let byline = model.byline {
            AteActionsSheet(
                title: "@\(byline.handle)",
                blockTitle: "Block @\(byline.handle)",
                onSavePlace: { Task { await model.toggleSaveEveryDish() } },
                onShare: { [] },
                onShareReceipt: { model.shareArtefact() },
                analytics: services.analytics,
                onReport: { Task { await model.report() } },
                onBlock: {
                    Task {
                        guard await model.blockAuthor() != nil else { return }
                        onBlocked()
                        dismiss()
                    }
                }
            )
        }
    }
}

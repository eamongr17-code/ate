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
/// order: the order number and the date, the place as the title, the photos as a tilted collage, the
/// person's own words with their tokens, and the bill between two dashed rules with the address and
/// the average under it.
///
/// There is no receipt here. The receipt is the artefact Ate prints for **sharing** — it is rendered
/// from `ReceiptView` at the moment of sharing and it has not changed — but the page a person reads
/// their own entry on is a page, not a printout of one.
///
/// Everything on it is still a correction: the title opens ``PlaceSheet``, a line opens ``DishSheet``
/// (`entry_corrected`), because the structure is Ate's guess and the person has the last word on it.
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
            page
                .padding(.horizontal, AteMetrics.pageInset)
                .padding(.top, AteMetrics.pageGap)
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
        .fullScreenCover(item: $model.viewingPhoto) { viewing in
            AtePhotoViewer(photos: model.photos, index: viewing.index)
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

    // MARK: - The page

    /// `.slip`: `padding:22px 20px 0`, `gap:14px`, `border-radius:24px 24px 0 0`, `min-height:760`.
    private var page: some View {
        VStack(alignment: .leading, spacing: AteMetrics.pageBandGap) {
            if let card = model.card {
                orderRow(card)
                if let place = card.place {
                    title(place, isMine: card.isMine)
                }
                photos
                words
                AteDashedRule()
                bill
                AteDashedRule()
                footer(card)
            }
        }
        .padding(.top, AteMetrics.pagePaddingTop)
        .padding(.horizontal, AteMetrics.pagePaddingSide)
        // The artboard has no bottom padding — its page simply continues past the screen. Ours can be
        // scrolled to the end, and a bill sitting on the cut edge would read as a crop.
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

    /// `ORDER #0142` left, the date right — the mono label row that opens the page.
    private func orderRow(_ card: EntryCard) -> some View {
        labelRow(
            leading: "Order #\(String(format: "%04d", card.orderNumber))",
            trailing: card.createdAt.formatted(AteReceipt.dateFormat)
        )
    }

    /// The address and the average close it. Either may be missing — design rule 2 says put the two
    /// values left and right or drop one; it never invents a separator or a placeholder.
    private func footer(_ card: EntryCard) -> some View {
        labelRow(
            leading: card.place?.address,
            trailing: card.avgScore.map {
                "Avg \(ScoreFormat.entryAverage($0))"
            }
        )
    }

    @ViewBuilder
    private func labelRow(leading: String?, trailing: String?) -> some View {
        if leading != nil || trailing != nil {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                if let leading { Text(leading) }
                Spacer(minLength: 0)
                if let trailing { Text(trailing) }
            }
            .ateText(.receiptLabel)
            // `.lab` is muted by default; the page overrides it to full ink on both of its rows.
            .foregroundStyle(AtePalette.slip.fg)
        }
    }

    /// **The place, at 38 — and the open question.**
    ///
    /// It goes two places: the place's own page, and ``PlaceSheet``, which changes the place and
    /// re-resolves every line at the new one. Which of them the *tap* opens is genuinely uncertain
    /// — the artboard wired the tap to the sheet, before those pages existed — so both are built
    /// and ``AteVariants/entryTapOpensDetail`` picks (AGENTS.md: two working variants, decided
    /// on-device). The other is always one long press away, with a word on it.
    ///
    /// Somebody else's entry has no correction, so its title always opens the page.
    private func title(_ place: EntryCard.Place, isMine: Bool) -> some View {
        let openPage = { onPlace(place.id) }
        let correct = { model.isCorrectingPlace = true }
        let tapOpensPage = isMine == false || tapOpensDetail
        return Button(action: tapOpensPage ? openPage : correct) {
            AteExactText(text: place.name, style: .entryPlace, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isMine {
                Button(tapOpensPage ? "Change the place" : "Open \(place.name)") {
                    tapOpensPage ? correct() : openPage()
                }
            }
            variantSwitch
        }
        .accessibilityLabel(place.name)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("entry.place")
    }

    /// Which gesture owns a tap on the title and on a bill line. Always `true` in a Release build:
    /// the variant machinery does not exist there, and the default is the one that ships.
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
        Divider()
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
                model.viewingPhoto = EntryModel.ViewingPhoto(index: index)
            }
        }
    }

    /// The person's own words, with their score and place pills still in them. `.prose` at 17 — the
    /// biggest the words are anywhere outside the composer.
    @ViewBuilder
    private var words: some View {
        if model.composition.plain.isEmpty == false {
            InlineTokenText(composition: model.composition, style: .proseLarge)
                .accessibilityIdentifier("entry.words")
        }
    }

    @ViewBuilder
    private var bill: some View {
        switch model.state {
        case .printed(let receipt):
            // Your own bill is a set of corrections; somebody else's is a set of bookmarks. The
            // structure is Ate's guess only where the words were yours.
            EntryBill(
                items: receipt.items,
                onOpen: { item in item.dishID.map(onDish) },
                onCorrect: model.isMine ? { model.correcting = EntryModel.Correcting(item: $0) } : nil,
                onSave: model.isMine ? nil : { item in Task { await model.toggleSave(item: item) } },
                tapOpensDetail: tapOpensDetail
            )
        case .pending, .failed:
            EntryPendingBill(state: model.state) {
                Task { await model.retrySort() }
            }
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
                Text(verbatim: "@\(byline.handle)")
                    .ateText(.controlSmall)
                Text(byline.age)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
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
        }
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

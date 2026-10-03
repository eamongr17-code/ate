import AteKit
import SwiftUI

/// **One entry, yours or somebody else's** — ``V2Destinations`` builds it. Keep the type name and
/// initialiser.
///
/// Read mode: the native inline bar with its back, the entry's whole paper (``AteEntryPaper``), and
/// the tab bar staying under it. **Yours**: the place and the day as the title, Share (the printed
/// receipt) and a ••• menu with Edit — the same composer sheet, filled in — and Delete, which asks
/// once. Every part of the paper is also a correction: a long press on a dish row fixes the dish, one
/// on the place line changes the place. **Somebody else's**: their byline as the title, a bookmark on
/// every dish, and ••• opening the one actions sheet (save, share a link, report, block).
///
/// The page's state is the current page's (``EntryModel``): drawn from the card it was opened with,
/// refreshed from the server, watching an unsorted entry until it prints.
struct V2EntryPage: View {
    let entry: EntryRoute
    let context: V2PageContext

    init(_ entry: EntryRoute, context: V2PageContext) {
        self.entry = entry
        self.context = context
    }

    var body: some View {
        // The viewer is hosted here: a photo on the page opens full screen with the native zoom.
        V2EntryScreen(entry: entry, context: context)
            .atePhotoViewerHost()
    }
}

private struct V2EntryScreen: View {
    let entry: EntryRoute
    let context: V2PageContext

    @State private var model: EntryModel
    @State private var isShowingActions = false
    @State private var isSharingReceipt = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.atePhotoViewer) private var showPhotos

    init(entry: EntryRoute, context: V2PageContext) {
        self.entry = entry
        self.context = context
        _model = State(initialValue: EntryModel(route: entry, services: context.services, saves: context.saves))
    }

    private var services: AteServices { context.services }

    var body: some View {
        content
            .ateGround()
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .task {
                services.savedDishes.add(model)
                await model.load()
            }
            .onChange(of: model.card) { _, card in
                if let card { NotificationCenter.ateEntryChanged(card) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ateV2EntryChanged)) { note in
                // An edit saved in the composer, or the receipt's place attached: read it again.
                guard let card = note.object as? EntryCard, card.id == entry.entryID, card != model.card else { return }
                Task { await model.reload() }
            }
            .v2PlaceSheet(
                isPresented: $model.isCorrectingPlace,
                directory: services.places,
                initialQuery: { model.card?.place?.name ?? "" },
                selected: { model.card?.restaurantID },
                onPick: { place in Task { await model.correctPlace(place) } }
            )
            .v2DishSheet(
                item: $model.correcting,
                directory: services.places,
                placeID: { model.card?.restaurantID },
                placeName: { model.card?.place?.name },
                onPick: { item, dishID, dishName in
                    Task { await model.correctDish(reviewID: item.id, dishID: dishID, dishName: dishName) }
                }
            )
            .sheet(isPresented: $isShowingActions) { actionsSheet }
            .sheet(isPresented: $isSharingReceipt) {
                if let receipt = model.receipt, let card = model.card {
                    V2ReceiptShareSheet(
                        receipt: receipt,
                        photoURLs: card.photos.sorted { $0.position < $1.position }.compactMap { URL(string: $0.url) },
                        analytics: services.analytics
                    )
                }
            }
            .v2FailureAlert($model.failure, analytics: services.analytics)
            .confirmationDialog(
                "Delete this entry?", isPresented: $model.isConfirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { if await model.delete() { dismiss() } }
                }
            }
            .alert("Couldn't reach Ate.", isPresented: $model.deleteFailed) {
                Button("OK", role: .cancel) {}
            }
    }

    // MARK: - The page

    @ViewBuilder
    private var content: some View {
        if let failure = model.loadFailure {
            // Two different answers: the phone or the server let us down (try again), or the entry
            // itself is gone, where a retry would be a button that never works.
            switch failure {
            case .unreachable:
                AteEmptyState(line: "Couldn't reach Ate.", pill: ("Try again", { Task { await model.retryLoad() } }))
            case .gone:
                AteEmptyState(line: "This entry\nis gone.")
                    .accessibilityIdentifier("entry.gone")
            }
        } else {
            ScrollView {
                Group {
                    if let card = model.card {
                        paper(card)
                            .transition(.opacity)
                    } else {
                        // Opened by id alone: the slip's skeleton until the read answers.
                        AteSkeleton(kind: .entrySlip)
                            .transition(.opacity)
                    }
                }
                .ateAnimation(AteMotion.fillIn, value: model.isLoaded)
                .padding(.horizontal, AteMetrics.pageInset)
                .padding(.top, AteMetrics.pageGap)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .accessibilityIdentifier("entry.page")
        }
    }

    private func paper(_ card: EntryCard) -> some View {
        AteEntryPaper(
            dishes: dishes,
            words: model.composition,
            photos: model.photos,
            place: card.place?.name,
            suburb: card.place?.suburb,
            day: RelativeAge.day(card.createdAt),
            onDish: { dish in openDish(dish, card: card) },
            onScoreDish: { context.open(.dish($0), from: .entry) },
            onCorrectDish: card.isMine ? { model.correct($0) } : nil,
            onSaveDish: card.isMine ? nil : { dish in Task { await model.toggleSave(dish: dish) } },
            onPlace: card.place.map { place in {
                PlacePreviews.shared.note(place.id, name: place.name)
                context.open(.place(place.id), from: .entry)
            } },
            // A place never attached is not guessed at: on your own entry the line attaches one.
            onCorrectPlace: card.isMine ? { model.isCorrectingPlace = true } : nil,
            onPhoto: { showPhotos(model.photos, at: $0) },
            onReprint: { Task { await model.retrySort() } }
        )
    }

    /// The dish rows lead — or, until the sorter has answered, their shape.
    private var dishes: AteEntryPaper.Dishes {
        switch model.state {
        case .printed: .rows(model.dishes)
        case .pending: .pending(isFailed: false)
        case .failed: .pending(isFailed: true)
        }
    }

    private func openDish(_ dish: AteSlip.Dish, card: EntryCard) {
        // Its page draws the name and the place at once.
        DishPreviews.shared.note(DishPreview(
            dishID: dish.dishID, name: dish.name,
            restaurantID: card.place?.id, restaurantName: card.place?.name
        ))
        context.open(.dish(dish.dishID), from: .entry)
    }

    // MARK: - The bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let card = model.card {
            ToolbarItem(placement: .topBarLeading) {
                if let byline = model.byline {
                    V2EntryByline(byline: byline) { context.open(.profile(byline.userID), from: .entry) }
                } else {
                    // A place never attached is not guessed at: the day alone is the title.
                    AteInlineTitle(
                        title: card.place?.name ?? RelativeAge.day(card.createdAt),
                        subtitle: card.place == nil ? nil : RelativeAge.day(card.createdAt)
                    )
                }
            }
            .sharedBackgroundVisibility(.hidden)
            if card.isMine {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSharingReceipt = true } label: {
                        AteIcon.share.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .disabled(model.receipt == nil)
                    .accessibilityLabel("Share receipt")
                    .accessibilityIdentifier("entry.share")
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit") { edit(card) }
                            .accessibilityIdentifier("entry.edit")
                        Button("Delete", role: .destructive) { model.isConfirmingDelete = true }
                            .accessibilityIdentifier("entry.delete")
                    } label: {
                        AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("entry.more")
                }
            } else if model.byline != nil {
                // With no author on the row (blocked, deleted) there is nobody to act on.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingActions = true } label: {
                        AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("entry.more")
                }
            }
        }
    }

    /// Edit reopens the same composer sheet, filled in.
    private func edit(_ card: EntryCard) {
        guard context.gate.permitsWrite(.compose) else { return }
        context.app.compose(.edit(card))
    }

    // MARK: - Somebody else's entry

    /// The one actions sheet — save the visit's dishes, share a link to it (never their receipt),
    /// report it, block them.
    @ViewBuilder
    private var actionsSheet: some View {
        if let byline = model.byline {
            AteActionsSheet(
                title: "@\(byline.handle)",
                blockTitle: "Block @\(byline.handle)",
                onSave: { Task { await model.toggleSaveEveryDish() } },
                isSaved: model.isEveryDishSaved,
                onShare: {
                    guard let card = model.card else { return [] }
                    return EntryLinkShare.items(for: card, handle: byline.handle)
                },
                onReport: { Task { await model.report() } },
                onBlock: {
                    Task {
                        guard await model.blockAuthor() != nil else { return }
                        dismiss()
                    }
                }
            )
            .environment(context.gate)
        }
    }
}

/// **The byline** in somebody else's entry's bar: their avatar, their handle, and how long ago. A
/// long handle truncates; the age never does. A tap opens their profile.
private struct V2EntryByline: View {
    let byline: AteByline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.snug) {
                AteAvatar(userID: byline.userID, handle: byline.handle, size: .byline)
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
            .foregroundStyle(AtePalette.automatic.fg)
            .frame(minHeight: AteMetrics.hit)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("@\(byline.handle), \(byline.age)")
        .accessibilityIdentifier("entry.byline")
    }
}

extension View {
    /// **A write that did not happen, said once** — one native alert line and OK, counted as
    /// `action_failed` the moment it shows (the current app's rule).
    func v2FailureAlert(_ failure: Binding<ActionFailure?>, analytics: @escaping AnalyticsRecorder) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if $0 == false { failure.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: failure.wrappedValue) { _, shown in
            guard let shown else { return }
            analytics(RecoveryEvents.actionFailed(shown))
        }
    }
}

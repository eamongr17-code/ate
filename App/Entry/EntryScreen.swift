import AteKit
import SwiftUI

/// Where an entry is opened from, and whether its receipt is about to print for the first time.
struct EntryRoute: Hashable, Identifiable {
    let entryID: UUID
    /// True when Done in the composer landed here: the receipt prints in on first appearance, once.
    var isFreshlyWritten = false

    var id: UUID { entryID }
}

/// Everywhere the Journal tab's stack can go. One type, because a `NavigationStack`'s path is one
/// type — and both destinations are pushes with the tab bar still under them.
enum JournalRoute: Hashable {
    case entry(EntryRoute)
    /// `Suggestions` — recent photos, offered as sittings to write up.
    case suggestions

    var entryID: UUID? {
        switch self {
        case .entry(let route): route.entryID
        case .suggestions: nil
        }
    }
}

/// **`Entry`** — the words on their own page, with the receipt feeding out from underneath them.
///
/// The overlap is the whole picture: the words card sits on top, the paper slides out from behind it
/// and stops, and the person sees the thing the app made from what they wrote. Everything tappable
/// on the receipt is a correction (`correct_entry_place`, `correct_entry_dish`) — the structure is
/// Ate's guess and the person has the last word on all of it.
struct EntryScreen: View {
    let route: EntryRoute
    let services: AteServices
    /// Called whenever the entry changes, so the journal behind this screen stays true.
    var onChange: (EntryCard) -> Void = { _ in }
    /// The pencil: reopen these words in the composer.
    var onEdit: (EntryCard) -> Void = { _ in }

    @State private var model: EntryModel
    @Environment(\.dismiss) private var dismiss

    init(
        route: EntryRoute,
        services: AteServices,
        onChange: @escaping (EntryCard) -> Void = { _ in },
        onEdit: @escaping (EntryCard) -> Void = { _ in }
    ) {
        self.route = route
        self.services = services
        self.onChange = onChange
        self.onEdit = onEdit
        _model = State(initialValue: EntryModel(route: route, services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let card = model.card {
                    words(card)
                    receipt(card)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.snug - 2)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .task { await model.load() }
        .onChange(of: model.card) { _, card in
            if let card { onChange(card) }
        }
        .sheet(isPresented: $model.isCorrectingPlace) { placeSheet }
        .sheet(item: $model.correcting) { correcting in dishSheet(correcting.item) }
        .sheet(isPresented: $model.isSharing) { shareSheet }
    }

    // MARK: - Bands

    /// Back / visibility / edit / share, exactly as `Entry.dc.html` sets them down. Icons only — the
    /// design puts labels nowhere near this row (rule 1).
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back to journal", size: 24) { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            if let card = model.card {
                AteIconButton(
                    icon: card.visibility.isPublic ? .publicEntry : .privateEntry,
                    label: card.visibility.isPublic ? "Public. Make private" : "Private. Make public",
                    size: 21
                ) {
                    Task { await model.toggleVisibility() }
                }
                AteIconButton(icon: .edit, label: "Edit", size: 21) { onEdit(card) }
                AteIconButton(icon: .share, label: "Share receipt", size: 22) { model.share() }
                    .disabled(model.receipt == nil)
                    .opacity(model.receipt == nil ? 0.35 : 1)
            }
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    // MARK: - Sheets

    /// The receipt's header. The *same* sheet the composer's Place key opens — the same action has
    /// to work identically everywhere it appears.
    private var placeSheet: some View {
        PlaceSheet(
            directory: services.places,
            initialQuery: model.card?.place?.name ?? "",
            selected: model.card?.restaurantID
        ) { place in
            Task { await model.correctPlace(place) }
        }
        .presentationDetents([.large])
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
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var shareSheet: some View {
        if let image = model.shareImage {
            ShareSheet(image: image)
        }
    }

    /// The words card: the person's own sentence with its tokens, and the tilted photo cluster. It
    /// overlaps the receipt, and it is drawn on paper because it is part of the same printing.
    private func words(_ card: EntryCard) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            InlineTokenText(composition: model.composition, style: .prose)
            if model.photos.isEmpty == false {
                PhotoCluster(
                    photos: model.photos,
                    side: AteMetrics.clusterPhotoLarge,
                    surface: AteColor.paper
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, AteMetrics.loose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atePaper()
        .ateBackground(
            AteColor.paper,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            shadow: .wordsCard
        )
        .zIndex(1)
    }

    @ViewBuilder
    private func receipt(_ card: EntryCard) -> some View {
        switch model.state {
        case .printed(let receipt):
            ReceiptView(
                receipt: receipt,
                topPadding: Self.topPadding,
                topRadius: 0,
                onPlaceTap: { model.isCorrectingPlace = true },
                onItemTap: { model.correcting = EntryModel.Correcting(item: $0) }
            )
            .padding(.horizontal, 22)
            .padding(.top, -Self.overlap)
            .atePrintsIn(model.hasPrinted)
            // `.contain` so the paper itself is a queryable element: its children are already
            // combined into rows, which would otherwise leave nothing addressable for a drive.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry.receipt")
        case .pending, .failed:
            EntryPendingSlip(state: model.state) {
                Task { await model.retrySort() }
            }
            .padding(.horizontal, 22)
            .padding(.top, -Self.overlap)
            .accessibilityIdentifier("entry.pending")
        }
    }

    /// How far the words card sits over the paper — the design's `margin:-16px`.
    private static let overlap: CGFloat = 16
    /// `Entry.dc.html`'s `padding:32px 16px 14px` on the receipt.
    private static let topPadding: CGFloat = 32
}

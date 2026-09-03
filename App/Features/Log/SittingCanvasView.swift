import AteKit
import SwiftUI

/// **The durable screen of a log session** (§4).
///
/// WHERE and WHAT are transient pushes that hand a value back; this is the only screen that persists
/// for the whole sitting, and the four moves that make n dishes feel like *one meal* all live here:
/// the restaurant is the title (never a field, never re-asked), "Add another dish" is a row in the
/// same list, there is one Post for all of them, and one receipt at the end.
///
/// It is a plain `List`, which is what makes swipe-to-delete, keyboard avoidance and Dynamic Type
/// free rather than bespoke.
struct SittingCanvasView: View {
    let model: LogSessionModel
    let sitting: SittingState
    let onAddDish: () -> Void
    let onPost: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            canvas
                // §4.3: a new card is scrolled into view, and the duplicate guard flashes the card
                // that's already there. Same mechanism, because to the person they're the same
                // question: "where did my dish go?"
                .onChange(of: model.highlightedCardID) { _, cardID in
                    guard let cardID else { return }
                    withAnimation(.snappy) { proxy.scrollTo(cardID, anchor: .center) }
                }
                .onChange(of: model.wiggleTrigger) { _, _ in
                    guard let cardID = model.highlightedCardID else { return }
                    withAnimation(.snappy) { proxy.scrollTo(cardID, anchor: .center) }
                }
        }
    }

    private var canvas: some View {
        List {
            if sitting.isEmpty {
                emptyState
            } else {
                ForEach(sitting.dishes) { dish in
                    composeCard(for: dish)
                        .id(dish.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(
                            top: Theme.Spacing.snug,
                            leading: Theme.Spacing.gutter,
                            bottom: Theme.Spacing.snug,
                            trailing: Theme.Spacing.gutter
                        ))
                }
                .onDelete { model.removeCards(atOffsets: $0) }

                addAnotherRow
            }
        }
        .listStyle(.plain)
        // A card always sits on recessed ground (Theme.Color.surfaceCard) — on the plane it would
        // be white on white. The canvas is the app's one screen with cards plural, so it takes the
        // recessed tone; the cards are what the screen is made of.
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
        .scrollDismissesKeyboard(.interactively)
        // §6.5 Reduce Motion: the insert crossfades instead of sliding.
        .animation(reduceMotion ? .easeInOut : .snappy, value: sitting.dishes.map(\.id))
        .navigationTitle(sitting.restaurant.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let suburb = sitting.restaurant.suburb {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(sitting.restaurant.name)
                            .font(Theme.Text.itemTitle)
                        Text(suburb)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
            }
        }
        // §1.2: Post is bottom-anchored and never scrolls away — for n=1 it must be reachable
        // without scrolling, and at accessibility sizes it must still be there.
        .safeAreaInset(edge: .bottom) { postBar }
    }

    // MARK: - Cards

    private func composeCard(for dish: SittingDish) -> some View {
        DishCard(
            model: DishCardModel(
                id: dish.id,
                dishName: dish.dishName,
                dishID: dish.dishID,
                restaurantName: sitting.restaurant.name,
                restaurantSuburb: sitting.restaurant.suburb,
                score: dish.score?.value,
                note: dish.trimmedNote,
                photo: model.photoURL(for: dish.id).map(DishCardPhoto.local)
            ),
            mode: .compose,
            actions: DishCardActions(
                rating: model.ratingBinding(for: dish.id),
                note: model.noteBinding(for: dish.id),
                onRatingChanged: { value, method in model.recordRatingSet(value, method: method) },
                onAddPhoto: { model.photoPickerCardID = dish.id },
                onRemovePhoto: { model.removePhoto(from: dish.id) },
                onRetryPhotoUpload: { model.retryPhotoUpload(for: dish.id) },
                onRemoveDish: { model.removeCard(dish.id) },
                onClearRating: { model.clearRating(for: dish.id) },
                photoUploadState: dish.photo?.uploadState,
                wiggleTrigger: model.highlightedCardID == dish.id ? model.wiggleTrigger : 0
            )
        )
    }

    /// §4.2 move 2: a row in the same list, not a floating button — adding a dish is part of the
    /// sitting, not an action performed on it.
    private var addAnotherRow: some View {
        Group {
            Button(action: onAddDish) {
                Label("Add another dish", systemImage: "plus.circle")
                    .font(Theme.Text.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(sitting.canAddAnother ? Theme.Color.accent : Theme.Color.textTertiary)
            .disabled(!sitting.canAddAnother)

            if !sitting.canAddAnother {
                Text("That's a big meal — post these first.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listRowBackground(Color.clear)
    }

    /// §4.4: reachable only by deleting the last card. Deleting doesn't dismiss — you're still at
    /// the restaurant.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No dishes yet", systemImage: "fork.knife")
        } description: {
            Text("Add the first dish from this sitting")
        } actions: {
            Button("Add a dish", action: onAddDish)
                .buttonStyle(.borderedProminent)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: - Post bar

    @ViewBuilder
    private var postBar: some View {
        if !sitting.isEmpty {
            VStack(spacing: Theme.Spacing.snug) {
                if let message = model.postFailureMessage {
                    // §6.4: a banner, not an alert. The dishes are still here and still yours.
                    Text(message)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    Task { await onPost() }
                } label: {
                    HStack(spacing: Theme.Spacing.snug) {
                        if model.isPosting { ProgressView().controlSize(.small) }
                        Text(model.postButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canPost)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.regular)
            .background(.bar)
        }
    }
}

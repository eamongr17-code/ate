import AteKit
import PhotosUI
import SwiftUI

/// **The log flow** (§1) — V1's core loop, in one sheet.
///
/// The structure is the product decision: WHERE and WHAT are *resolution* steps, pushed and popped,
/// and the **Sitting Canvas is the only durable screen**. That is what lets one visit to one
/// restaurant produce n reviews with one Post and one receipt, instead of n trips through a
/// form. The canvas is therefore the stack's root; the pickers are pushed above it, even at open,
/// which is why an initial `path` is set in `init` (SwiftUI renders an initial path without a push
/// animation, so the sheet still opens *on* the picker).
///
/// **Integration:** the host presents `LogSheet(entry:services:)` from the `+` tab and gets
/// `onFinished` back with the rows that were written, for its own cache/refresh.
struct LogSheet: View {
    @State private var model: LogSessionModel
    @State private var path: [LogRoute]
    @State private var isLeaveDialogPresented = false
    @State private var photoItem: PhotosPickerItem?

    private let onFinished: (PostedSitting) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - entry: §1.1 — decides which step the sheet opens on. Nothing else varies.
    ///   - onFinished: what was posted — the rows *and* the display names they were written under,
    ///     so the host can put the sitting on the diary without a round trip (§7.4).
    ///
    /// There is no `onOpenDish`: the receipt is Share + Done, and nothing in the sheet navigates
    /// outside it. The seam comes back the day something needs it.
    init(
        entry: LogEntry,
        services: LogServices,
        onFinished: @escaping (PostedSitting) -> Void = { _ in }
    ) {
        _model = State(initialValue: LogSessionModel(entry: entry, services: services))
        _path = State(initialValue: LogRoute.initialPath(for: entry))
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: LogRoute.self, destination: destination)
        }
        .task { model.start() }
        // A swipe-dismissed sheet runs neither Cancel nor Done, so this is where its claim on the
        // draft is handed back deterministically (§6.4's retry must not wait on a deallocation).
        .onDisappear { model.releaseDraftCheckouts() }
        // §7: leaving with something composed asks; leaving with nothing doesn't.
        .interactiveDismissDisabled(model.hasContent)
        .onChange(of: scenePhase) { _, phase in
            // §6.5: an interruption is not a decision anyone should have to make.
            if phase != .active { model.persistOnInterruption() }
        }
        .photosPicker(
            isPresented: Binding(
                get: { model.photoPickerCardID != nil },
                set: { if !$0 { model.photoPickerCardID = nil } }
            ),
            selection: $photoItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItem) { _, item in
            guard let item, let cardID = model.photoPickerCardID else { return }
            // §5.1: the upload starts on pick, in the background — by Post time it's usually done.
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.attachPhoto(data, to: cardID)
                }
                model.photoPickerCardID = nil
                photoItem = nil
            }
        }
        .confirmationDialog("Save this sitting?", isPresented: $isLeaveDialogPresented, titleVisibility: .visible) {
            Button("Save draft") { leave(savingDraft: true) }
            Button("Discard", role: .destructive) { leave(savingDraft: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can pick it up from the log screen for the next week.")
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var root: some View {
        if let sitting = model.sitting {
            SittingCanvasView(
                model: model,
                sitting: sitting,
                onAddDish: { path.append(.what) },
                onPost: post
            )
            .toolbar { canvasToolbar }
        } else {
            // Never seen: with no sitting the stack always has WHERE pushed on top of this.
            Color.clear
        }
    }

    @ViewBuilder
    private func destination(_ route: LogRoute) -> some View {
        switch route {
        case .whereStep:
            whereStep
        case .what:
            whatStep
        case .rate(let cardID):
            rateStep(cardID: cardID)
        case .receipt:
            receiptStep
        }
    }

    /// [1] WHERE — resolve the restaurant. Never asked twice in a sitting (§4.2).
    private var whereStep: some View {
        SearchPicker(
            subject: .restaurants,
            context: .pick,
            services: model.searchServices,
            onSelect: { selection in
                guard case .restaurant(let picked) = selection else { return }
                model.resolveRestaurant(picked)
                // WHERE stays *under* WHAT until a dish lands: picking the wrong Chin Chin is a
                // real mistake, and Back has to undo it. The moment a card exists, both pickers
                // are dropped from the stack (see the WHAT step) and the restaurant is never
                // asked again (§4.2).
                path = [.whereStep, .what]
            }
        )
        .navigationTitle("Where?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { attemptLeave(from: .whereStep) }
            }
            ToolbarItem(placement: .primaryAction) { LogDebugMenu() }
        }
        // §7 Continue: SearchPicker owns its own sections and takes no injected header, so the
        // resume affordance is pinned above it rather than forked into it. Flagged to the lead as
        // the one picker-API gap the log flow hit.
        .safeAreaInset(edge: .top) { continueRow }
    }

    @ViewBuilder
    private var continueRow: some View {
        if let draft = model.resumableDraft {
            // Two sibling buttons, never nested: a discard button *inside* the resume button is a
            // tap-target lottery.
            HStack(spacing: Theme.Spacing.regular) {
                Button {
                    model.resumeDraft()
                    path = []
                } label: {
                    HStack(spacing: Theme.Spacing.regular) {
                        Image(systemName: "arrow.uturn.forward")
                            .foregroundStyle(Theme.Color.accent)
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text(draft.sitting.restaurant.name)
                                .font(Theme.Text.itemTitle)
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text(continueSubtitle(draft))
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        Spacer(minLength: Theme.Spacing.snug)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    model.discardResumableDraft()
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard draft")
            }
            .padding(Theme.Spacing.comfortable)
            .background(Theme.Color.surface)
        }
    }

    private func continueSubtitle(_ draft: LogDraft) -> String {
        let age = draft.savedAt.formatted(.relative(presentation: .numeric))
        return "\(draft.dishCountSummary) · \(age)"
    }

    /// [2] WHAT — resolve a dish within the sitting's restaurant.
    @ViewBuilder
    private var whatStep: some View {
        if let sitting = model.sitting {
            SearchPicker(
                subject: .dishes(
                    restaurantID: sitting.restaurant.id,
                    restaurantName: sitting.restaurant.name
                ),
                context: .pick,
                services: model.searchServices,
                onSelect: { selection in
                    guard case .dish(let picked) = selection else { return }
                    let cardID = model.addDish(picked)
                    // §2.6 variant B: a brand-new card gets its own focused rating step; a duplicate
                    // pick just returns to the card that already exists.
                    if model.variant == .rateOnSelect,
                       let cardID,
                       model.sitting?[cardID]?.score == nil {
                        path = [.rate(cardID: cardID)]
                    } else {
                        path = []
                    }
                }
            )
            .navigationTitle(sitting.restaurant.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// §2.6 variant B only: one dish, one big track, one Done.
    @ViewBuilder
    private func rateStep(cardID: UUID) -> some View {
        if let dish = model.sitting?[cardID] {
            RatingStepView(
                dishName: dish.dishName,
                rating: model.ratingBinding(for: cardID),
                onChange: { value, method in model.recordRatingSet(value, method: method) },
                onDone: { path = [] }
            )
        }
    }

    @ViewBuilder
    private var receiptStep: some View {
        if let receipt = model.receipt {
            ReceiptView(
                receipt: receipt,
                model: model,
                onDone: {
                    model.endSession(step: .receipt, savedDraft: false)
                    // Read before `dismiss()`: the model is torn down with the sheet, and the host's
                    // optimistic insert is the whole point of this call.
                    if let posted = model.postedSitting { onFinished(posted) }
                    dismiss()
                }
            )
        }
    }

    @ToolbarContentBuilder
    private var canvasToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { attemptLeave(from: .canvas) }
        }
        ToolbarItem(placement: .primaryAction) { LogDebugMenu() }
    }

    // MARK: - Actions

    private func post() async {
        await model.post()
        if model.receipt != nil {
            path = [.receipt]
        }
    }

    private func attemptLeave(from step: LogStep) {
        if model.hasContent {
            isLeaveDialogPresented = true
        } else {
            leave(savingDraft: false, step: step)
        }
    }

    private func leave(savingDraft: Bool, step: LogStep = .canvas) {
        if savingDraft {
            model.saveDraft()
        } else {
            model.discardDraft()
        }
        model.endSession(step: step, savedDraft: savingDraft)
        dismiss()
    }
}

/// The pushed steps. The canvas is not in here — it is the root, which is the whole point (§1).
enum LogRoute: Hashable {
    case whereStep
    case what
    case rate(cardID: UUID)
    case receipt

    static func initialPath(for entry: LogEntry) -> [LogRoute] {
        switch entry {
        case .tab: [.whereStep]
        case .restaurant: [.what]
        case .dish, .resume: []
        }
    }
}

/// §2.6 variant B: the rate-on-select step.
struct RatingStepView: View {
    let dishName: String
    @Binding var rating: Rating?
    let onChange: (Rating, LogRatingMethod) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            Text(dishName)
                .font(Theme.Text.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            RatingControl(rating: $rating, onChange: onChange)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(rating == nil)
        }
        .padding(Theme.Spacing.comfortable)
        .navigationBarTitleDisplayMode(.inline)
    }
}

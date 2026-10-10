import AteKit
import SwiftUI

/// **Adding yours** ("Ate with", `ate-with.html` section 3, option A) — the composer's prefilled face,
/// shown by ``ComposerSheet`` when it is opened with `respondingTo`. The tagger's place and dishes,
/// read live: the place as the title, "with @them" and the visit's day under it, then the dishes as
/// the entry's rows, each with an empty slot. The composer's own score slide sits at the foot on the
/// highlighted row; letting go fills it and moves on, so three dishes are three drags. Swipe a row
/// for Remove (a dish they did not have). Words are optional and the keyboard stays down until they
/// are tapped. The tick is live from the start and posts THEIR OWN entry; the sheet then turns to the
/// printed receipt, exactly as any entry does.
struct AteWithRespondFace: View {
    let app: AppModel
    let companionID: UUID
    /// The printed receipt is up over the rows.
    var isCovered = false
    let onPrinted: (V2ComposerPrinted.Handoff) -> Void

    @State private var model: AteWithRespondModel
    @State private var saveFailed = false
    @State private var isConfirmingClose = false
    @FocusState private var isWriting: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        companionID: UUID,
        isCovered: Bool = false,
        onPrinted: @escaping (V2ComposerPrinted.Handoff) -> Void
    ) {
        self.app = app
        self.companionID = companionID
        self.isCovered = isCovered
        self.onPrinted = onPrinted
        _model = State(initialValue: AteWithRespondModel(
            companionID: companionID, service: app.services.ateWith, analytics: app.services.analytics
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: nil, primary: model.phase == .gone ? nil : tick) { requestClose() }
                .allowsHitTesting(model.isPosting == false)
            content
                .allowsHitTesting(model.isPosting == false)
            slide
        }
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
        .background { AtePalette.surface.ground.ignoresSafeArea() }
        .interactiveDismissDisabled(isCovered == false && (hasWork || model.isPosting))
        .ateAnimation(V2ComposerMotion.slider, value: model.current)
        .confirmationDialog("Discard entry?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
        }
        .alert("Couldn't reach Ate.", isPresented: $saveFailed) {
            Button("Try again") { post() }
            Button("Cancel", role: .cancel) {}
        }
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in settle(phase) }
        .accessibilityIdentifier("respond")
    }

    // MARK: - The corners

    private var tick: AteSheetPrimary {
        AteSheetPrimary(icon: .check, label: "Post", isEnabled: model.canPost, isBusy: model.isPosting, action: post)
    }

    private var hasWork: Bool {
        model.lines.contains { $0.score != nil } || model.removedCount > 0
            || model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func requestClose() {
        if hasWork { isConfirmingClose = true } else { dismiss() }
    }

    // MARK: - The rows

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading, .unreachable:
            skeleton
        case .gone:
            AteEmptyState(line: AteWithCopy.gone, art: .torn)
                .accessibilityIdentifier("respond.gone")
        case .answered:
            Color.clear
        case .ready:
            List {
                if let prefill = model.prefill {
                    header(prefill).plainRow()
                }
                ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                    AteScoringDishRow(
                        dishID: line.dishID,
                        name: line.name,
                        score: line.score,
                        isCurrent: model.current == line.id,
                        showsRule: index > 0
                    ) {
                        isWriting = false
                        model.select(line.id)
                    }
                    .padding(.horizontal, AteMetrics.gutter - AteScoringDishRowMetrics.currentInset)
                    .plainRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(AteWithCopy.remove, role: .destructive) { model.remove(line.id) }
                            .tint(AteColor.destructive)
                    }
                    .accessibilityAction(named: AteWithCopy.remove) { model.remove(line.id) }
                }
                words.plainRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .transition(.opacity)
        }
    }

    /// The place, then "with @them" beside their avatar and the visit's day at the right.
    private func header(_ prefill: AteWithPrefill) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            if let place = prefill.place {
                Text(place.name)
                    .ateText(.sheetTitle)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: AteMetrics.snug) {
                AteAvatar(userID: prefill.tagger.id, handle: prefill.tagger.username, size: .byline)
                let handle = Text(verbatim: "@\(prefill.tagger.username)")
                    .fontWeight(.semibold)
                    .foregroundStyle(AtePalette.surface.fg)
                Text("with \(handle)")
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.surface.muted)
                    .lineLimit(1)
                Spacer(minLength: AteMetrics.snug)
                Text(RelativeAge.day(prefill.visitedAt))
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.surface.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.snug)
        .padding(.bottom, AteMetrics.regular)
    }

    /// The words: optional, the keyboard down until they are tapped.
    private var words: some View {
        TextField(AteWithCopy.placeholder, text: $model.body, axis: .vertical)
            .ateText(.composerProse)
            .focused($isWriting)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.regular)
            .padding(.bottom, AteMetrics.section)
            .accessibilityIdentifier("respond.words")
    }

    /// The place line and the rows' still shapes; the slide waits for the first row.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            AteSkeletonBar(width: AteWithMetrics.titleBar, height: AteWithMetrics.titleBarHeight,
                           palette: .surface)
            AteSkeletonBar(width: AteWithMetrics.metaBar, height: AteWithMetrics.metaBarHeight, palette: .surface)
            AteEntryPendingRows()
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateSkeletonSweep()
        .accessibilityHidden(true)
    }

    // MARK: - The slide

    /// The composer's own score slide, on the highlighted row. Folded away while the words are being
    /// written and once every row is done.
    @ViewBuilder
    private var slide: some View {
        if model.phase == .ready, isWriting == false, let current = model.current,
           let line = model.lines.first(where: { $0.id == current }) {
            VStack(spacing: 0) {
                StarSlider(
                    dishName: line.name,
                    rating: Binding(
                        get: { model.lines.first { $0.id == current }?.score },
                        set: { if let rating = $0 { model.slide(to: rating) } }
                    ),
                    allowsSix: true
                ) { rating in
                    model.finish(at: rating)
                }
                .id(current)
                .padding(.top, AteMetrics.regular)
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.bottom, AteMetrics.regular)
            .transition(reduceMotion ? AnyTransition.opacity : V2ComposerMotion.sliderRising)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("respond.slide")
        }
    }

    // MARK: - Posting

    private func post() {
        isWriting = false
        Task {
            do {
                let card = try await model.post()
                app.notifications.finished(companionID: companionID)
                NotificationCenter.ateEntryChanged(card)
                onPrinted(V2ComposerPrinted.Handoff(card: card, photos: [], sorted: nil, tagTokens: [], sixTokens: []))
            } catch AteWithError.unreachable {
                saveFailed = true
            } catch {
                // Withdrawn, declined or answered elsewhere: the phase says so, and the row goes.
            }
        }
    }

    /// What a read or a post found out, carried to the list and the bell.
    private func settle(_ phase: AteWithRespondModel.Phase) {
        switch phase {
        case .ready:
            app.notifications.opened(companionID: companionID)
            Task { await app.notifications.refreshCount() }
        case .gone:
            app.notifications.finished(companionID: companionID)
        case .answered(let entryID):
            // Already theirs: their entry opens instead, on the tab under the sheet.
            app.notifications.finished(companionID: companionID)
            app.linkedEntry = entryID
            dismiss()
        case .loading, .unreachable:
            break
        }
    }
}

private extension View {
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum AteWithCopy {
    static let gone = "This visit isn't here."
    static let remove = "Remove"
    static let placeholder = "What did you have today?"
}

enum AteWithMetrics {
    static let titleBar: CGFloat = 150
    static let titleBarHeight: CGFloat = 26
    static let metaBar: CGFloat = 120
    static let metaBarHeight: CGFloat = 13
}

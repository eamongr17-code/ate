import AteKit
import SwiftUI

/// **The Diary** — your eating, organised in time (§3).
///
/// The feed is a list of reviews; this is a record. That difference is structural, not decorative:
/// the date is the spine (month sections → sitting blocks), the rows are compact lines rather than
/// cards, and there is no byline and no aggregate anywhere on the screen — you know who wrote these,
/// and what everyone else scored the dish is a different page.
///
/// Two things are always here that aren't part of reading: the composer, and the resume row when a
/// sitting was left unfinished. The composer is present and enabled in **every** phase except signed
/// out — including loading and failed — because logging a dish must never wait on a read of your
/// history. That rule is asserted in `DiaryComposerPolicyTests`.
///
/// No edit or delete affordances: V1 has no review-mutation path (PRODUCT.md), and a context menu
/// that can't do anything is worse than none.
struct DiaryView: View {
    @State private var store: DiaryStore
    /// Owned by the tab scaffold, not by this view: finishing a log has to land you on the diary
    /// *at its root*, and only the host can clear a stack it doesn't otherwise see (§7).
    @Binding private var path: NavigationPath
    /// Where the list is scrolled. Held here so the host can ask for the top without knowing what
    /// the list is made of.
    @State private var scrollPosition = ScrollPosition()
    /// The unfinished sitting, if there is one. Cached rather than read per layout pass — it comes
    /// off the filesystem. Refreshed on appearance and whenever the log sheet closes.
    @State private var draft: LogDraft?

    /// §11's A/B, read live so flipping the toggle re-lays out immediately.
    @AppStorage(DiaryDebugSettings.composerPlacementKey)
    private var composerPlacementRaw = DiaryComposerPlacement.topOfList.rawValue

    /// Bumped by the host each time the already-selected Diary tab is tapped again. A counter rather
    /// than a Bool: two taps in a row must scroll twice, and there is nothing to reset.
    private let scrollToTopSignal: Int
    /// Bumped by the host whenever the log sheet closes — the one moment the draft can have changed
    /// without this view being involved.
    private let draftRefreshSignal: Int
    /// How this stack builds detail screens — the app's one API client, or fixtures in previews.
    private let detail: DetailContext
    /// Composing, resuming, discarding, and the one link out to the feed.
    private let actions: DiaryActions
    /// The staging-only sign-in affordance until the real auth flow lands. Debug builds only.
    private let debugSignIn: DebugStagingSignIn?
    /// "Staging · Supabase cvoit…" — which backend this build is talking to, so a test drive can
    /// never mistake one environment for another. Nil in Release, where it must not appear.
    private let environmentFootnote: String?

    init(
        store: DiaryStore,
        path: Binding<NavigationPath>,
        detail: DetailContext,
        actions: DiaryActions = .none,
        scrollToTopSignal: Int = 0,
        draftRefreshSignal: Int = 0,
        debugSignIn: DebugStagingSignIn? = nil,
        environmentFootnote: String? = nil
    ) {
        _store = State(initialValue: store)
        _path = path
        self.detail = detail
        self.actions = actions
        self.scrollToTopSignal = scrollToTopSignal
        self.draftRefreshSignal = draftRefreshSignal
        self.debugSignIn = debugSignIn
        self.environmentFootnote = environmentFootnote
    }

    private var composerPlacement: DiaryComposerPlacement {
        #if DEBUG
        DiaryComposerPlacement(rawValue: composerPlacementRaw) ?? .topOfList
        #else
        .topOfList
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Diary")
                // The record line, in the stock place for a line under a large title. §3.1 shows it
                // as the title's second line, and iOS 26 has exactly that — nothing hand-built.
                .modifier(RecordLine(text: store.recordLine))
                .toolbar { toolbar }
                // Registered once, at this stack's root: every dish, restaurant and journal entry
                // reached from the diary — including onward pushes inside detail — resolves here as
                // `source: .diary`.
                .detailDestinations(source: .diary, context: detail)
                // Lets screens deep in this stack push routes and is where restaurant_name_tapped fires.
                .stackRouting(path: $path, analytics: detail.analytics)
        }
        // On the stack rather than on its content, so a push-then-pop within the tab is not a new
        // "view". This fires on each *tab* appearance, which is what makes a review posted in the
        // Log sheet show up here without an app restart (the store marks itself stale on post).
        .onAppear {
            store.recordDiaryViewed()
            refreshDraft()
            Task { await store.loadIfNeeded() }
        }
        // Tapping the selected Diary tab again goes back to the top — the standard iOS answer to
        // "take me home" — and never opens the log sheet.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation { scrollPosition.scrollTo(edge: .top) }
        }
        .onChange(of: draftRefreshSignal) { _, _ in refreshDraft() }
        // §3.4: signed out has no composer and therefore nothing to resume into.
        .onChange(of: store.phase) { _, phase in
            if phase == .signedOut { draft = nil }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Debug builds only, by construction: the host passes nil in Release, so there is no build
        // where this can leak into a shipped bar.
        if let environmentFootnote {
            ToolbarItem(placement: .topBarTrailing) {
                Text(environmentFootnote)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        ToolbarItem(placement: .primaryAction) { DiaryDebugMenu() }
    }

    // MARK: - Phases

    /// §3.4's precedence, spelled out in one place: signedOut > failed > empty > ready.
    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .signedOut:
            signedOut
        case .failed(let message):
            diaryList { failedSection(message) }
        case .empty:
            diaryList { firstRunSection }
        case .loading:
            diaryList { loadingSection }
        case .ready:
            diaryList { recordSections }
        }
    }

    /// The list every non-signed-out phase is made of. One `List`, one composer, one refresh — the
    /// body changes underneath and the top of the screen does not move. That is what makes the first
    /// log *not* relayout the diary (§3.5).
    @ViewBuilder
    private func diaryList(@ViewBuilder body: () -> some View) -> some View {
        List {
            if composerPlacement == .topOfList {
                composerSection
            }
            body()
        }
        .listStyle(.plain)
        // §1.1: the diary is a PLANE — rows sit directly on the background, parted by hairlines.
        .background(Theme.Color.background)
        .scrollPosition($scrollPosition)
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if composerPlacement == .pinned {
                pinnedComposer
            }
        }
    }

    // MARK: - Composer

    /// Resume above composer, both scrolling away with the list (variant A).
    @ViewBuilder
    private var composerSection: some View {
        Section {
            if store.phase.allowsComposer, let draft, let onResume = actions.resumeDraft {
                DiaryResumeRow(
                    draft: draft,
                    onResume: {
                        store.recordLogCTATapped(from: .diaryResume)
                        onResume()
                    },
                    onDiscard: discardDraft
                )
                .listRowSeparator(.hidden)
            }
            if store.phase.allowsComposer, let logDish = actions.logDish {
                DiaryComposerRow(origin: composerOrigin) {
                    store.recordLogCTATapped(from: composerOrigin)
                    logDish(composerOrigin)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Variant B — the same two rows, pinned. Same action, same event; only the placement differs.
    @ViewBuilder
    private var pinnedComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            if store.phase.allowsComposer, let draft, let onResume = actions.resumeDraft {
                DiaryResumeRow(
                    draft: draft,
                    onResume: {
                        store.recordLogCTATapped(from: .diaryResume)
                        onResume()
                    },
                    onDiscard: discardDraft
                )
            }
            if store.phase.allowsComposer, let logDish = actions.logDish {
                DiaryComposerRow(origin: composerOrigin) {
                    store.recordLogCTATapped(from: composerOrigin)
                    logDish(composerOrigin)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.snug)
        .background(.bar)
    }

    /// The same button, but the first one ever tapped is the number that says whether the first-run
    /// page works — so it reports itself differently (§9).
    private var composerOrigin: LogCTAOrigin {
        store.phase == .empty ? .diaryEmpty : .diaryComposer
    }

    // MARK: - Body sections

    /// Month sections of sitting blocks — the diary proper.
    @ViewBuilder
    private var recordSections: some View {
        ForEach(store.months) { month in
            Section {
                ForEach(month.sittings) { sitting in
                    sittingBlock(sitting)
                }
            } header: {
                monthHeader(month)
            }
        }

        if store.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.regular)
                .listRowSeparator(.hidden)
        }

        if let message = store.inlineErrorMessage {
            inlineError(message) { await store.loadMore() }
        }
    }

    private func monthHeader(_ month: DiaryMonth) -> some View {
        HStack {
            Text(month.representativeDate.formatted(.dateTime.month(.wide).year()))
            Spacer(minLength: Theme.Spacing.snug)
            Text(DiaryRecordLine.dishCount(month.dishCount))
        }
        .textCase(nil)
    }

    /// A sitting: its header, then its dishes. Not a drawn box — the header is what makes the run of
    /// rows read as one visit, and native separators do the rest.
    @ViewBuilder
    private func sittingBlock(_ sitting: DiarySitting) -> some View {
        // §1.2: no hairline before a header. A rule there parts a thing from its heading rather
        // than one sibling from the next, which is what made the old list read as a grid.
        DiarySittingHeader(sitting: sitting) { path.append($0) }
            .streamRow(showsDivider: false)
            .padding(.top, Theme.Spacing.snug)

        ForEach(sitting.entries) { entry in
            Button {
                store.recordTap(on: entry)
                // §3.3: the tap opens *your entry*, not the public dish page. The two are one
                // disclosure row apart, and keeping them separate is what stops the boundary
                // blurring the way it did in the legacy build.
                path.append(DiaryEntryRoute(reviewID: entry.id))
            } label: {
                DiaryEntryRow(entry: entry)
            }
            .buttonStyle(.plain)
            // The app's ONE inset hairline (§1.2): between two dishes of the same sitting the rule
            // starts at the text column, so the block reads as one visit. The last dish of a sitting
            // gets none — the next thing down is a header.
            .streamRow(
                showsDivider: entry.id != sitting.entries.last?.id,
                dividerLeadingInset: DiaryEntryRow.textColumnInset
            )
            .task { await store.loadMoreIfNeeded(after: entry) }
        }
    }

    /// Redacted rows in the shape the content will have, not a spinner: the list is already right
    /// when the entries land.
    @ViewBuilder
    private var loadingSection: some View {
        let placeholders = FeedPlaceholder.entries(count: 4)
        Section {
            ForEach(placeholders) { entry in
                DiaryEntryRow(entry: entry)
                    .streamRow(
                        showsDivider: entry.id != placeholders.last?.id,
                        dividerLeadingInset: DiaryEntryRow.textColumnInset
                    )
            }
        } header: {
            Text("Loading")
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading your diary")
    }

    /// §3.5 — the diary with nothing in it. Not a `ContentUnavailableView`: nothing is unavailable,
    /// and the composer above must stay exactly where it will be forever, so the first log doesn't
    /// move the screen.
    @ViewBuilder
    private var firstRunSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                Text(
                    """
                    Your record starts here. Rate a dish and it lands on this page — \
                    what you ate, where, and what you thought.
                    """
                )
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textSecondary)

                // The only reference to the feed anywhere on the diary, and only in this phase
                // (§3.5, §8). A plain text button — it is a way out of an empty page, not a
                // competing call to action.
                if let showFeed = actions.showFeed {
                    Button("See what everyone's eating", action: showFeed)
                        .font(Theme.Text.detail)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Theme.Spacing.regular)
            .listRowSeparator(.hidden)
        }
    }

    /// §3.4: the error goes *below* the composer, inline. Never an alert — a failed read of your
    /// history is not something to interrupt anyone about, and the thing they came to do still works.
    @ViewBuilder
    private func failedSection(_ message: String) -> some View {
        Section {
            inlineError(message) { await store.retry() }
        }
    }

    private func inlineError(_ message: String, retry: @escaping () async -> Void) -> some View {
        VStack(spacing: Theme.Spacing.snug) {
            Text(message)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Button("Try again") { Task { await retry() } }
                .font(Theme.Text.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.regular)
        .listRowSeparator(.hidden)
    }

    /// Signed out is NOT the empty state. RLS answers an anonymous read with a successful empty
    /// page, so without this screen we would tell a stranger that *they* had logged nothing.
    private var signedOut: some View {
        ContentUnavailableView {
            Label("Sign in to see your diary", systemImage: "person.crop.circle")
        } description: {
            Text("Everything you log is kept here, newest first.")
        } actions: {
            if let debugSignIn {
                Button(debugSignIn.title) {
                    Task {
                        await debugSignIn.signIn()
                        await store.retry()
                    }
                }
            }
        }
    }

    // MARK: - Draft

    private func refreshDraft() {
        guard store.phase != .signedOut else {
            draft = nil
            return
        }
        draft = actions.loadDraft?()
    }

    private func discardDraft() {
        actions.discardDraft?()
        withAnimation { draft = nil }
    }
}

/// The record line, applied only when there is one — an empty subtitle is still a subtitle, and it
/// would leave a gap under the title on the phases (§3.4) where the line is meant to be absent.
private struct RecordLine: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("Diary") {
    DiaryPreviewHost()
}

/// The diary's stack lives in the tab scaffold, so a preview has to stand in as its host — a
/// `.constant` path would silently swallow every push.
private struct DiaryPreviewHost: View {
    @State private var path = NavigationPath()

    var body: some View {
        DiaryView(
            store: DiaryStore(client: PreviewDiaryClient(), pageSize: 12),
            path: $path,
            detail: DetailContext(dataSource: PreviewDetailDataSource(), analytics: DetailTelemetry.none),
            actions: DiaryActions(logDish: { _ in }, showFeed: {})
        )
    }
}

/// Preview-only backend: the placeholder entries, paged.
private struct PreviewDiaryClient: DiaryReading {
    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        Page(items: FeedPlaceholder.entries(count: request.limit), nextCursor: nil)
    }
}
#endif

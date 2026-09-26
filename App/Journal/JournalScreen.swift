import AteKit
import SwiftUI

/// **`Main`** — home. The logo, the Journal | Saved segment, and your entries newest first — each
/// slip carrying its own day at the right of its foot line, so the list needs no headings.
///
/// Journal is the app's front door (PRODUCT.md decision 1): you write for yourself, and the record
/// you keep is the first thing you see. Saved lives beside it because a dish you meant to eat belongs
/// next to the dishes you did.
struct JournalScreen: View {
    let store: JournalStore
    /// The shelf beside it. Held by the shell rather than this screen, because a save made in the
    /// feed has to be able to tell it to reload.
    let saved: SavedDishesStore
    /// Bumped when the Journal tab is tapped while already current.
    var scrollToTopSignal = 0
    /// How many recent photos are waiting to be written up — the header badge. Zero hides it, which
    /// is also what no photo-library permission looks like (`MainEmpty` draws the button unbadged).
    var photoCount = 0
    let onCompose: () -> Void
    let onOpen: (EntryCard) -> Void
    var onSuggestions: () -> Void = {}
    /// A slip's pin line and its dish rows — the same doors the feed's slips carry.
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    /// A saved row's two doors: the place head, and the dish itself.
    var onSavedPlace: (UUID) -> Void = { _ in }
    var onSavedDish: (SavedDish) -> Void = { _ in }
    /// The bookmark on a saved row: it only ever unsaves.
    var onUnsave: (SavedDish) -> Void = { _ in }

    enum Shelf: Hashable {
        case journal, saved
    }

    @State private var shelf: Shelf = {
        #if DEBUG
        return ComposerDebugLaunch.opensSaved ? .saved : .journal
        #else
        return .journal
        #endif
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    AteSegments(
                        options: [AteSegment(Shelf.journal, "Journal"), AteSegment(Shelf.saved, "Saved")],
                        selection: $shelf
                    )
                    .padding(.horizontal, AteMetrics.listGutter)
                    .padding(.top, AteMetrics.loose)
                    .id(Self.topAnchor)
                    shelfContent
                }
                // Design rule 10: the last slip runs off under the tab bar rather than
                // stopping dead above it.
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
            .task { await store.loadIfNeeded() }
        }
    }

    private static let topAnchor = "journal.top"
    /// `MainEmpty`: `padding:16px 12px 110px; gap:22px; flex:1` — the first-day state sits 22 under
    /// the segment, centred on the one line every empty state shares (``AteEmptyPlacement``).
    private static let firstDayGap: CGFloat = 22
    /// Where the segment ends on the page: the 60 content top, the 44 header, the 16 above the
    /// segment and the segment's own 44.
    private static let segmentBottom: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.loose
        + AteMetrics.segmentHeight + 2 * AteMetrics.tight
    /// Where a shelf's empty state begins on the screen — Journal and Saved alike.
    private static let emptyTop: CGFloat = segmentBottom + firstDayGap

    private var header: some View {
        HStack {
            AteWordmark()
            Spacer(minLength: AteMetrics.snug)
            PhotoStackButton(count: photoCount, action: onSuggestions)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .ateContentTop()
    }

    /// Pull to refresh reloads whichever shelf is showing — the gesture belongs to the screen, and
    /// the screen is two lists.
    private func refresh() async {
        switch shelf {
        case .journal: await store.refresh()
        case .saved: await saved.refresh()
        }
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .journal:
            // `Main` parts the segment from the first slip by the column's own 14; `MainEmpty`
            // centres its state in the page below (`firstDay`).
            journalShelf.padding(.top, store.phase == .ready || store.phase == .loading
                ? AteMetrics.slipGap : Self.firstDayGap)
        case .saved:
            // `Saved.dc.html` parts the segment from the first place head by the column's own 14,
            // and the head carries its own 18 on top of that. An empty shelf is a slip, and gets
            // the margin a slip gets.
            SavedScreen(
                store: saved,
                emptyTop: Self.emptyTop,
                onPlace: onSavedPlace,
                onDish: onSavedDish,
                onUnsave: onUnsave
            )
            .padding(.top, saved.phase == .ready || saved.phase == .loading ? AteMetrics.slipGap : Self.firstDayGap)
        }
    }

    @ViewBuilder
    private var journalShelf: some View {
        switch store.phase {
        case .loading:
            SlipSkeleton().padding(.horizontal, AteMetrics.listGutter)
        case .empty:
            firstDay(AteEmptyState(title: "Nothing\non the tab.", actionTitle: "Write your first", action: onCompose))
        case .signedOut:
            firstDay(AteEmptyState(title: "Nobody's\nsigned in."))
        case .failed:
            firstDay(AteUnreachableState { Task { await store.refresh() } })
        case .ready:
            slips
        }
    }

    /// `MainEmpty` — the state, centred in the page under the segment. No paper: an empty journal
    /// has not printed anything, so it does not wear the receipt.
    private func firstDay(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: Self.emptyTop)
    }

    private var slips: some View {
        LazyVStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(store.entries) { entry in
                EntrySlip(
                    slip: EntrySlipPresentation.journal(entry),
                    onOpen: { onOpen(entry) },
                    onPlace: onPlace,
                    onDish: { onDish($0.dishID) }
                )
                .task { await store.loadMoreIfNeeded(after: entry) }
                // Its own task, so the row scrolling away cancels the prefetch with it.
                .task { await AtePrefetch.photos(after: entry, in: store.entries) }
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

/// **The journal's one header control**: a chip-coloured disc with the photo-stack mark, and a coral
/// badge carrying how many recent photos are waiting to be written up. It opens `Suggestions`.
struct PhotoStackButton: View {
    var count: Int
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteIcon.photoStack.view(size: 20)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .background(palette.chip, in: .circle)
                .foregroundStyle(palette.fg)
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 photo to write up" : "\(count) photos to write up")
        .accessibilityIdentifier("journal.suggestions")
    }

    @ViewBuilder
    private var badge: some View {
        if count >= 1 {
            Text(count.formatted())
                .ateText(.badge)
                .foregroundStyle(AteColor.ink)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(AteColor.coral, in: .capsule)
                .offset(x: 3, y: -3)
        }
    }
}

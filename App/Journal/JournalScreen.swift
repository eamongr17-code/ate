import AteKit
import SwiftUI

/// **`Main`** — home. The logo, the Journal | Saved segment, and your entries newest first, grouped
/// under the day they happened.
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
    /// A saved row's two doors — both to screens that land in slice 2.
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
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, AteMetrics.loose)
                    .id(Self.topAnchor)
                    shelfContent
                }
                // Design rule 10: the last slip runs off under the tab bar's scrim rather than
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
    /// `MainEmpty`: the column's 22 gap plus the slip's own 26 margin.
    private static let emptyTop: CGFloat = 48

    private var header: some View {
        HStack {
            AteWordmark()
            Spacer(minLength: AteMetrics.snug)
            PhotoStackButton(count: photoCount, action: onSuggestions)
        }
        .padding(.horizontal, AteMetrics.gutter)
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
            // `Main` parts the segment from the first day label by the column's own 14; `MainEmpty`
            // gives its slip 22 + a 26 margin before it.
            journalShelf.padding(.top, store.days.isEmpty ? Self.emptyTop : AteMetrics.slipGap)
        case .saved:
            // `Saved.dc.html` starts straight under the segment: the first place head carries its
            // own 18. An empty shelf is a slip, and gets the margin a slip gets.
            SavedScreen(
                store: saved,
                onPlace: onSavedPlace,
                onDish: onSavedDish,
                onUnsave: onUnsave
            )
            .padding(.top, saved.groups.isEmpty ? Self.emptyTop : 0)
        }
    }

    @ViewBuilder
    private var journalShelf: some View {
        switch store.phase {
        case .loading:
            SlipSkeleton().padding(.horizontal, AteMetrics.gutter)
        case .empty:
            emptySlip
        case .signedOut:
            AteEmptySlip(label: "Ate", title: "Nobody's\nsigned in.")
        case .failed(let message):
            AteEmptySlip(label: "Journal", title: message)
        case .ready:
            days
        }
    }

    private var emptySlip: some View {
        AteEmptySlip(
            label: "Order #0001",
            title: "Nothing\non the tab.",
            prose: "Eat something good,\nthen tell us about it.",
            actionTitle: "Write your first",
            action: onCompose
        )
    }

    private var days: some View {
        LazyVStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(store.days) { day in
                Text(day.title)
                    .ateText(.controlSmall)
                    .padding(.top, AteMetrics.snug - 2)
                ForEach(day.entries) { entry in
                    EntrySlip(slip: EntrySlipPresentation.journal(entry)) {
                        onOpen(entry)
                    }
                    .task { await store.loadMoreIfNeeded(after: entry) }
                }
            }
            if let message = store.inlineErrorMessage {
                Text(message)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AteMetrics.regular)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
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

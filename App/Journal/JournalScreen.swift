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
    /// Bumped when the Journal tab is tapped while already current.
    var scrollToTopSignal = 0
    let onCompose: () -> Void
    let onOpen: (EntryCard) -> Void

    enum Shelf: Hashable {
        case journal, saved
    }

    @State private var shelf: Shelf = .journal

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
            .refreshable { await store.refresh() }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
            .task { await store.loadIfNeeded() }
        }
    }

    private static let topAnchor = "journal.top"

    private var header: some View {
        HStack {
            AteWordmark()
            Spacer(minLength: AteMetrics.snug)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.contentTop)
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .journal:
            journalShelf.padding(.top, store.days.isEmpty ? AteMetrics.section : AteMetrics.loose)
        case .saved:
            AteEmptySlip(label: "Saved", title: "Nothing saved\nyet.")
                .padding(.top, AteMetrics.section)
        }
    }

    @ViewBuilder
    private var journalShelf: some View {
        switch store.phase {
        case .loading:
            JournalSkeleton()
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
                    JournalSlip(slip: JournalPresentation.slip(for: entry)) {
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

/// Turning a row into the slip the design draws. Kept beside the screen and free of state, so "what
/// does this entry look like in a list" is one function.
enum JournalPresentation {
    static func slip(for entry: EntryCard) -> AteSlip {
        AteSlip(
            id: entry.id,
            // An entry with no place yet still belongs on the journal — it shows the day it
            // happened where the place will go, rather than a blank or a guess.
            place: entry.place?.name ?? entry.createdAt.formatted(JournalGrouping.dayFormat),
            isPublic: entry.visibility.isPublic,
            words: EntryPresentation.composition(for: entry),
            photos: entry.photos.map { AtePhoto(url: URL(string: $0.url)) },
            items: entry.items.map {
                AteReceipt.Item(id: $0.reviewID, name: $0.dishName, score: $0.score)
            }
        )
    }
}

/// First load, drawn as the component it is waiting for — never a spinner (`docs/DESIGN.md`).
struct JournalSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: AteMetrics.regular) {
                    AteDashedRule()
                    AteDashedRule()
                    AteDashedRule()
                }
                .padding(AteMetrics.slipPadding)
                .padding(.bottom, AteMetrics.tornEdgeHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .atePaper()
                .background(AteColor.paper, in: ReceiptPaper())
                .opacity(0.6)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityHidden(true)
    }
}

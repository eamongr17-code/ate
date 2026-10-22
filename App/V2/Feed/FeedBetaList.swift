import AteKit
import SwiftUI

/// **The beta Feed** (``AteBeta``, `beta-feed` mockup, Eamon 11 Oct): every receipt printed on Ate,
/// newest first, from everywhere, paged as you read. No area, no sections; the approved slip,
/// unchanged. The end rule shows only when there is nothing older.
struct FeedBetaList: View {
    let store: EntryListStore
    let actions: FeedEditionActions
    @Environment(\.atePalette) private var palette

    var body: some View {
        switch store.phase {
        case .loading:
            ForEach(0..<FeedBetaMetrics.skeletons, id: \.self) { index in
                AteSkeleton(kind: .entrySlip)
                    .ateCardWidth()
                    .padding(.top, index == 0 ? 0 : AteMetrics.slipGap)
            }
            .transition(.opacity)
        case .empty:
            empty(AteEmptyState(line: "Nobody's written\nanything yet.", art: .rail))
                .accessibilityIdentifier("state.empty")
        case .signedOut:
            empty(AteEmptyState(line: "Nobody's\nsigned in.", art: .printer))
        case .failed:
            empty(AteEmptyState(line: "Couldn't\nreach Ate.", art: .torn, pill: ("Try again", retry)))
                .accessibilityIdentifier("state.unreachable")
        case .ready:
            slips
        }
    }

    @ViewBuilder
    private var slips: some View {
        let entries = store.entries
        // Save, taught once, on the first dish of the first slip somebody else wrote.
        let tipped = entries.first { $0.isMine == false && $0.items.isEmpty == false }?.id
        ForEach(entries) { entry in
            FeedSlip(entry: entry, actions: actions, saveTip: entry.id == tipped ? SaveTip() : nil)
                .padding(.top, entry.id == entries.first?.id ? 0 : AteMetrics.slipGap)
                .task { await store.loadMoreIfNeeded(after: entry) }
                .task { await AtePrefetch.photos(after: entry, in: entries) }
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.section)
                .ateCardWidth()
        } else if store.hasReachedEnd {
            AteEndRule(line: "You're caught up")
                .accessibilityIdentifier("feed.caughtUp")
        }
    }

    private func empty(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

enum FeedBetaMetrics {
    static let skeletons = 3
}

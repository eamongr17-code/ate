import AteKit
import SwiftUI

/// **The Summary** — what follows Done in the composer (`SummaryLoading` → `SummaryFinal`,
/// 2026-09-26). The entry's receipt is the hero on the coral ground, printing while the sorter works:
/// the place, the photos, the order number and the date print at once; the lines are skeleton bars
/// with a slow breath, and no word says "printing". When the sort lands the receipt settles and
/// Share comes on — the existing share path, the same picture the Share screen sends.
///
/// Done lands on the entry's own page, which the shell has already put under this screen.
struct SummaryScreen: View {
    @State private var store: EntrySummaryStore
    /// The composer's staged photos — the entry's own are still uploading, and these are the same
    /// pictures, already in memory.
    let photos: [AtePhoto]
    /// Who signs the receipt, until the row's own author is there to.
    let handle: String
    let analytics: AnalyticsRecorder
    let onDone: () -> Void

    @State private var sender = ShareSender()

    init(
        card: EntryCard,
        photos: [AtePhoto],
        handle: String,
        fetch: @escaping @Sendable (UUID) async throws -> EntryCard,
        analytics: @escaping AnalyticsRecorder,
        onDone: @escaping () -> Void
    ) {
        _store = State(initialValue: EntrySummaryStore(card: card, fetch: fetch))
        self.photos = photos
        self.handle = handle
        self.analytics = analytics
        self.onDone = onDone
    }

    var body: some View {
        ShareStage(
            artefact: artefact,
            photos: Array(photos.prefix(2)),
            isPrinting: store.phase != .printed,
            breathes: store.phase == .sorting,
            didFail: sender.didFail,
            onDone: done,
            onShare: share
        )
        .task { await store.watch() }
        .sheet(item: $sender.sending) { sending in
            ShareSheet(items: [sending.image])
        }
        .accessibilityIdentifier("summary")
    }

    /// The row as a receipt — dish rows and scores only, never a note (Eamon, 2026-09-26).
    private var artefact: ShareArtefact {
        let receipt = EntryPresentation.receipt(for: store.card, handle: handle)
        return .entry(receipt, photos: store.card.photos.compactMap { URL(string: $0.url) })
    }

    private func done() {
        analytics(EntryEvents.summaryDone(entryID: store.card.id, wasPrinted: store.phase == .printed))
        onDone()
    }

    private func share() {
        guard store.phase == .printed else { return }
        analytics(EntryEvents.summaryShared(entryID: store.card.id))
        sender.send(artefact: artefact, photos: Array(photos.prefix(2))) {
            analytics(EntryEvents.receiptShared(entryID: store.card.id, source: .summary))
        }
    }
}

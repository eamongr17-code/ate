import AteKit
import Foundation

extension ComposerModel {
    /// What the save path is handed. The body is the words **verbatim** — `composition.plain`, with
    /// the tokens' own characters still in them, because that is what the person wrote and the
    /// sorter reads (design rule 9).
    func request(from draft: EntryDraft, photoDirectory: URL) -> NewEntryRequest {
        NewEntryRequest(
            id: draft.id,
            body: draft.composition.plain,
            restaurantID: draft.restaurantID,
            photoPaths: draft.photoFiles.map { photoDirectory.appending(path: $0).path() },
            createdAt: draft.eatenAt.map { EatenDay.clamped($0) } ?? draft.startedAt,
            scoreCount: draft.composition.scores.count,
            secondsFromOpen: draft.secondsFromOpen(),
            tagTokens: draft.composition.tagTokens,
            sixTokens: draft.composition.sixTokens
        )
    }
}

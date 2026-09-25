import Foundation
import Testing
@testable import AteKit

/// The funnel's names and parameters, pinned.
///
/// These assertions are the contract with the dashboard: a renamed event or a dropped dimension is a
/// series that silently goes to zero, which is indistinguishable from a feature nobody uses. That is
/// the failure this suite exists to make loud.
@Suite("Entry events — the core loop's funnel")
struct EntryEventsTests {

    @Test("the funnel's names are exactly the ones the brief asks for")
    func names() {
        #expect(EntryEvents.composerOpened(source: .tabBar, isResumingDraft: false).name
            == "entry_composer_opened")
        #expect(EntryEvents.scoreTokenCreated(source: .key).name == "entry_score_token_created")
        #expect(EntryEvents.placeAttached(source: .picked).name == "entry_place_attached")
        #expect(EntryEvents.saved(.init(photoCount: 0, hasPlace: false, scoreCount: 0,
                                        secondsFromOpen: 0)).name == "entry_saved")
        #expect(EntryEvents.sortCompleted(mode: "stub", itemCount: 0, durationMilliseconds: 0,
                                          didAttachPlace: false).name == "entry_sort_completed")
        #expect(EntryEvents.receiptPrinted(itemCount: 0, hasAverage: false).name == "receipt_printed")
        #expect(EntryEvents.corrected(.place).name == "entry_corrected")
    }

    @Test("a score token records which of the three ways it arrived")
    func scoreSources() {
        for source in ScoreTokenSource.allCases {
            let event = EntryEvents.scoreTokenCreated(source: source)
            #expect(event.parameters["source"] == source.rawValue)
        }
        #expect(ScoreTokenSource.allCases.map(\.rawValue).sorted() == ["dictation", "key", "typed"])
    }

    @Test("a place records the only two ways design rule 8 allows")
    func placeSources() {
        #expect(PlaceAttachSource.allCases.map(\.rawValue).sorted() == ["named", "picked"])
        #expect(EntryEvents.placeAttached(source: .named).parameters["source"] == "named")
    }

    @Test("a correction is split by part, because the two are different failures")
    func correctionParts() {
        #expect(EntryEvents.corrected(.place).parameters["part"] == "place")
        #expect(EntryEvents.corrected(.dish).parameters["part"] == "dish")
    }

    @Test("every composer entry point has a name — an unlabelled one reads as zero")
    func composerOrigins() {
        #expect(ComposerOrigin.allCases.map(\.rawValue).sorted()
            == ["entry_edit", "journal_empty", "photo_suggestion", "tab_bar"])
        let event = EntryEvents.composerOpened(source: .journalEmpty, isResumingDraft: true)
        #expect(event.parameters["source"] == "journal_empty")
        #expect(event.parameters["resumed_draft"] == "true")
    }

    @Test("entry_saved carries the whole shape of what was written")
    func savedParameters() {
        let event = EntryEvents.saved(.init(
            photoCount: 3, hasPlace: true, scoreCount: 2,
            secondsFromOpen: 96, wasQueued: true
        ))
        #expect(event.parameters == [
            "photo_count": "3",
            "has_place": "true",
            "score_count": "2",
            "seconds_from_open": "96",
            "queued": "true"
        ])
    }

    @Test("a clock that ran backwards is not a negative duration")
    func durationsAreNeverNegative() {
        let saved = EntryEvents.saved(.init(photoCount: 0, hasPlace: false, scoreCount: 0,
                                            secondsFromOpen: -5))
        #expect(saved.parameters["seconds_from_open"] == "0")
        let sorted = EntryEvents.sortCompleted(mode: "model", itemCount: 3,
                                               durationMilliseconds: -1, didAttachPlace: true)
        #expect(sorted.parameters["duration_ms"] == "0")
    }

    @Test("the sorter's mode is reported verbatim, so stub and model share one series")
    func sortMode() {
        let event = EntryEvents.sortCompleted(mode: "model", itemCount: 3,
                                              durationMilliseconds: 820, didAttachPlace: true)
        #expect(event.parameters == [
            "mode": "model", "items": "3", "duration_ms": "820", "attached_place": "true"
        ])
    }
}

#if DEBUG
@Suite("Preview sorter — previews and tests only")
struct PreviewSorterTests {

    @Test("the design's own entry comes back as three lines")
    func designEntry() {
        let lines = PreviewSorter.sort(body:
            "Tipo 00 with Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, "
                + "glossy, gone in four minutes. Tiramisu 3.0 a bit flat after that.")

        #expect(lines.count == 2)
        #expect(lines[0].dishName == "tagliatelle al ragù")
        #expect(lines[0].score?.value == 4.5)
        #expect(lines[0].note == "was unreal, rich, glossy, gone in four minutes.")
        #expect(lines[1].score?.value == 3.0)
    }

    @Test("a decimal point is never a full stop — the first bug the real corpus caught")
    func decimalsDoNotEndSentences() {
        let lines = PreviewSorter.sort(body: "Cheeseburger 1.5 and I want those minutes back.")
        #expect(lines.count == 1)
        #expect(lines[0].note == "and I want those minutes back.")
    }

    @Test("sentiment never becomes a score, however strong")
    func sentimentIsNotAScore() {
        #expect(PreviewSorter.sort(body: "The pork bun was unreal, best thing on the street.").isEmpty)
    }

    @Test("a number with no dish in front of it is not a line")
    func numberAloneIsNotALine() {
        #expect(PreviewSorter.sort(body: "4.5").isEmpty)
    }
}
#endif

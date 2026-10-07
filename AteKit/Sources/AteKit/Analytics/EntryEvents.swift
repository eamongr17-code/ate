import Foundation

/// Where the composer was opened from. A closed set: an unlabelled entry point reads as zero, and
/// this is the first step of the funnel that decides whether the composer works at all (PRODUCT.md —
/// "the strategy is falsified if people install, browse, and don't write").
public enum ComposerOrigin: String, Sendable, CaseIterable, Codable {
    /// The `+` in the tab bar.
    case tabBar = "tab_bar"
    /// "Write your first" on an empty journal.
    case journalEmpty = "journal_empty"
    /// The pencil on an entry — editing words that already exist.
    case entryEdit = "entry_edit"
    /// A cluster of recent photos on `Suggestions`, opened from the journal's header.
    case photoSuggestion = "photo_suggestion"
}

/// How a score token got into the words. The three are genuinely different products: the Score key
/// is a designed control, typing a number is the shortcut power users find, and dictation is the
/// at-the-table path. Which one people actually use decides where the next composer work goes.
public enum ScoreTokenSource: String, Sendable, CaseIterable, Codable {
    /// Typed as digits and moved on ("…ragù 4.5 was").
    case typed
    /// The butter Score key, then a slide.
    case key
    /// Spoken through the keyboard's mic.
    case dictation
}

/// How a place got attached. Design rule 8 allows exactly two ways, and this proves there is no
/// third: `named` is the sorter finding the place in the words, `picked` is a tap in the place sheet.
public enum PlaceAttachSource: String, Sendable, CaseIterable, Codable {
    case named
    case picked
}

/// Which part of a receipt the person corrected. The share of receipts that get edited is the
/// sorter's quality metric (PRODUCT.md), and it is only meaningful split this way: a wrong place is a
/// matching failure, a wrong dish is a parsing failure, and they are fixed in different code.
public enum EntryCorrection: String, Sendable, CaseIterable, Codable {
    case place
    case dish
}

/// Where a receipt was sent from. A closed set, because the north-star question is *which surface
/// actually produces shares*: the entry page's share icon, the actions sheet behind a slip's "…",
/// or a monthly statement.
public enum ReceiptShareSource: String, Sendable, CaseIterable, Codable {
    /// The share icon on the entry page.
    case entry
    /// The Share row in the actions sheet — the feed, the journal, a profile.
    case actions
    /// The share icon on a monthly statement (`Recap`).
    case statement
    /// The Summary that follows Done in the composer — the receipt as the hero on the coral ground.
    case summary
    /// "Instagram Stories" in the share sheet: the receipt as a sticker in IG's story editor.
    case instagramStories = "instagram_stories"
}

/// **The core loop's funnel**, built here so the names and parameters are asserted by tests and can
/// never drift, and sent by the app target's ``AnalyticsRecorder``.
///
/// `+` → `entry_composer_opened` → `entry_score_token_created` / `entry_place_attached` →
/// `entry_saved` → `entry_sort_completed` → `receipt_printed`, with `entry_corrected` hanging off the
/// end. Every step answers one question the brief asks: does anyone open it, do they score inside the
/// words, does the sorter get it right, and does the receipt actually arrive.
public enum EntryEvents {

    public static func composerOpened(source: ComposerOrigin, isResumingDraft: Bool) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_composer_opened",
            parameters: ["source": source.rawValue, "resumed_draft": flag(isResumingDraft)]
        )
    }

    /// `isPhrase`: the score was said in words ("four and a half", "a solid four", "4 out of 5" —
    /// ``ScorePhrase``) rather than typed as a number. Sent as `form=phrase` only then, so the
    /// existing series is byte-for-byte what it was.
    public static func scoreTokenCreated(source: ScoreTokenSource, isPhrase: Bool = false) -> AnalyticsEvent {
        var parameters = ["source": source.rawValue]
        if isPhrase { parameters["form"] = "phrase" }
        return AnalyticsEvent(name: "entry_score_token_created", parameters: parameters)
    }

    /// **The secret 6** came out on the slider — held past 5.0 until the sixth star appeared. Counted
    /// once per pill that ends the slide on 6, so it reads as "how many 6s were given", never as how
    /// often someone wobbled at the end of the track.
    public static func scoreSix() -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_score_six")
    }

    public static func placeAttached(source: PlaceAttachSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_place_attached", parameters: ["source": source.rawValue])
    }

    /// What an entry was, at the moment it was saved. One value rather than six arguments, so a new
    /// dimension is added in one place and every call site keeps compiling.
    public struct SavedEntry: Sendable, Hashable {
        public var photoCount: Int
        public var hasPlace: Bool
        public var scoreCount: Int
        /// The brief's entry-friction metric: seconds from `+` to Done.
        public var secondsFromOpen: Int
        /// True when the insert could not reach the server and went to the outbox instead.
        public var wasQueued: Bool

        public init(
            photoCount: Int,
            hasPlace: Bool,
            scoreCount: Int,
            secondsFromOpen: Int,
            wasQueued: Bool = false
        ) {
            self.photoCount = photoCount
            self.hasPlace = hasPlace
            self.scoreCount = scoreCount
            self.secondsFromOpen = secondsFromOpen
            self.wasQueued = wasQueued
        }
    }

    /// The words landed. Fired when the INSERT succeeds — including the `23505` that means it had
    /// already landed — because that is the moment the person's entry exists.
    public static func saved(_ entry: SavedEntry) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_saved",
            parameters: [
                "photo_count": String(entry.photoCount),
                "has_place": flag(entry.hasPlace),
                "score_count": String(entry.scoreCount),
                "seconds_from_open": String(max(0, entry.secondsFromOpen)),
                "queued": flag(entry.wasQueued)
            ]
        )
    }

    /// The sorter answered. `mode` is the server's own (`stub` | `model`), never inferred, so the day
    /// model mode is switched on the two are comparable in the same series.
    public static func sortCompleted(
        mode: String,
        itemCount: Int,
        durationMilliseconds: Int,
        didAttachPlace: Bool
    ) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_sort_completed",
            parameters: [
                "mode": mode,
                "items": String(itemCount),
                "duration_ms": String(max(0, durationMilliseconds)),
                "attached_place": flag(didAttachPlace)
            ]
        )
    }

    /// A sort failed or never arrived. Not in the brief's list, but a funnel that only counts the
    /// happy path reports a broken sorter as silence.
    public static func sortFailed(reason: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_sort_failed", parameters: ["reason": reason])
    }

    /// The receipt printed — the promise, kept. Fired once per entry per appearance of the printed
    /// state, which is the only moment the artefact exists for the person who wrote it.
    public static func receiptPrinted(itemCount: Int, hasAverage: Bool) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "receipt_printed",
            parameters: ["items": String(itemCount), "has_average": flag(hasAverage)]
        )
    }

    // MARK: - The camera key

    /// A photo was taken with the camera key. `photo_count` is how many the entry carries afterwards,
    /// which separates "took one" from "kept shooting".
    public static func cameraCaptured(photoCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_camera_captured",
            parameters: ["photo_count": String(max(0, photoCount))]
        )
    }

    /// `Suggestions` left photos out for not being food (on-device Vision, ``FoodPhotoFilter``).
    /// `count` is how many were left out, `kept` how many were offered — the ratio says whether the
    /// threshold is right. Sent only by a pass that classified something new, so a warm cache is
    /// silent and a launch is not a signal.
    public static func suggestionFiltered(count: Int, kept: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "suggestion_filtered",
            parameters: ["count": String(max(0, count)), "kept": String(max(0, kept))]
        )
    }

    public static func corrected(_ part: EntryCorrection) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_corrected", parameters: ["part": part.rawValue])
    }

    /// The receipt left the app. The loop's last step (PRODUCT.md — "the receipt is the marketing"),
    /// and the north-star event, which is why it carries **which** receipt and **where the share
    /// started**: the share sheet, the actions sheet and a monthly statement are three different
    /// products wearing one button.
    ///
    /// `entry_id` is absent for a statement, which is a receipt with no entry behind it — an empty
    /// string would read as a real id in a query.
    public static func receiptShared(entryID: UUID?, source: ReceiptShareSource) -> AnalyticsEvent {
        var parameters = ["source": source.rawValue]
        if let entryID { parameters["entry_id"] = entryID.uuidString.lowercased() }
        return AnalyticsEvent(name: "receipt_shared", parameters: parameters)
    }

    /// A dietary code typed after a dish became a tag chip in the composer (`DietTagsB`).
    public static func dishTagAdded(_ tag: DietTag) -> AnalyticsEvent {
        AnalyticsEvent(name: "dish_tag_added", parameters: ["code": tag.rawValue])
    }

    /// The Diet key was pressed for a code the dish already wears, and took it back off.
    public static func dishTagRemoved(_ tag: DietTag) -> AnalyticsEvent {
        AnalyticsEvent(name: "dish_tag_removed", parameters: ["code": tag.rawValue])
    }

    /// The Summary after Done: its ink **Share** was tapped (the share itself is still counted by
    /// `receipt_shared`, with `source=summary`, at the moment the image leaves)…
    public static func summaryShared(entryID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "summary_shared", parameters: ["entry_id": entryID.uuidString.lowercased()])
    }

    /// …or its white **Done** was, and whether the receipt had printed by then — a Done before the
    /// sort landed says the wait was longer than anyone would sit through.
    public static func summaryDone(entryID: UUID, wasPrinted: Bool) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "summary_done",
            parameters: ["entry_id": entryID.uuidString.lowercased(), "printed": flag(wasPrinted)]
        )
    }

    /// "Posting…" ended and the Summary came up (round 5): `outcome` is whether the sort answered
    /// inside the hold (`sorted`), answered with nothing to print (`unprinted`), or was still out
    /// (`late`); `ms` is how long the pill held, from the tap. The distribution sets ``PostHold``.
    public static func postHeld(outcome: PostHold.Outcome, milliseconds: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_post_held",
            parameters: ["outcome": outcome.rawValue, "ms": String(max(0, milliseconds))]
        )
    }

    /// The Summary's receipt printed its lines. `wait_ms` is how long the printed face stood before
    /// them (0 when the sort had landed by the time it came up).
    ///
    /// Build 87 (note 11) adds the number the speed work is judged by: `ms_from_done`, from the tap
    /// on Post to the lines printing, and `cache_hit` — whether an early sort of exactly these words,
    /// tokens and place had been sent before Done (the server's cache key; the server's own
    /// `sort_meta.cache_hit` is the confirmation). Both absent from the older Summary.
    public static func summaryReceiptEntered(
        entryID: UUID,
        waitMilliseconds: Int,
        millisecondsFromDone: Int? = nil,
        cacheHit: Bool? = nil
    ) -> AnalyticsEvent {
        var parameters = [
            "entry_id": entryID.uuidString.lowercased(), "wait_ms": String(max(0, waitMilliseconds))
        ]
        if let millisecondsFromDone { parameters["ms_from_done"] = String(max(0, millisecondsFromDone)) }
        if let cacheHit { parameters["cache_hit"] = flag(cacheHit) }
        return AnalyticsEvent(name: "summary_receipt_entered", parameters: parameters)
    }

    /// An early sort (`sort-entry`, `preview: true`) went out while the person was still writing.
    /// `nth` is its place in the session's ration of twelve — the distribution says whether the
    /// trigger fires once at a pause or chatters.
    public static func earlySortSent(nth: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_early_sort_sent", parameters: ["nth": String(max(0, nth))])
    }

    /// Done could not save. The composer stays open with "Try again" on the pill; `edit` separates a
    /// new entry from a rewrite of an old one.
    public static func saveFailed(isEdit: Bool, reason: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_save_failed", parameters: ["edit": flag(isEdit), "reason": reason])
    }

    /// Done stopped waiting on picks still being written (a slow iCloud original): the entry was
    /// saved without them, and they follow through the outbox. `count` is how many were late.
    public static func photoLate(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_photo_late", parameters: ["count": String(max(0, count))])
    }

    /// A picked photo could not be read at all — `stage` is `pick` (in the composer) or `late`
    /// (after Done). Never silent.
    public static func photoFailed(stage: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_photo_failed", parameters: ["stage": stage])
    }

    /// A staged photo was taken back out of the composer. `photo_count` is how many are left.
    public static func photoRemoved(photoCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_photo_removed", parameters: ["photo_count": String(max(0, photoCount))])
    }

    /// One of your own entries was deleted — after the server agreed, never at the tap. How much
    /// went with it is the question: a person deleting photo-heavy visits is telling us something
    /// different from one clearing out a stray line.
    public static func deleted(photoCount: Int, dishCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_deleted",
            parameters: ["photo_count": String(max(0, photoCount)), "dish_count": String(max(0, dishCount))]
        )
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }
}

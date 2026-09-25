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

/// Why dictation could not run. Three genuinely different failures: one is a permission the person
/// refused, one is a permission Apple asks for separately, and one is the phone simply not offering a
/// recogniser for the language. Split, because only the first two are anything the app can act on.
public enum VoiceDenialReason: String, Sendable, CaseIterable, Codable {
    /// The microphone was refused.
    case microphone
    /// Speech recognition was refused.
    case speech
    /// No recogniser for this locale, or the recogniser is not available right now.
    case unavailable
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

    public static func scoreTokenCreated(source: ScoreTokenSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_score_token_created", parameters: ["source": source.rawValue])
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

    // MARK: - The mic key, and the camera key
    //
    // Dictation is the at-the-table path: the composer's premise is that you write while the plate is
    // still in front of you, and talking is the only way that happens with one hand. So it gets its own
    // three steps — started, refused, used — beside the funnel rather than inside it. A score it mints
    // reports as `entry_score_token_created(source: "dictation")`, which already exists, so the two
    // input methods sit in one series.

    /// The mic key was tapped and the recogniser started listening.
    public static func voiceStarted() -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_voice_started")
    }

    /// Dictation ended with words in the composer. `word_count` is what was said; `token_count` is how
    /// many score tokens that dictation minted — the question being whether people actually score with
    /// their voice or only describe.
    public static func voiceCommitted(wordCount: Int, tokenCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_voice_committed",
            parameters: [
                "word_count": String(max(0, wordCount)),
                "token_count": String(max(0, tokenCount))
            ]
        )
    }

    /// Dictation could not run. Sent per attempt, so the series reads as "how often does somebody reach
    /// for this and not get it".
    public static func voiceDenied(reason: VoiceDenialReason) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_voice_denied", parameters: ["reason": reason.rawValue])
    }

    /// A photo was taken with the camera key. `photo_count` is how many the entry carries afterwards,
    /// which separates "took one" from "kept shooting".
    public static func cameraCaptured(photoCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "entry_camera_captured",
            parameters: ["photo_count": String(max(0, photoCount))]
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

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }
}

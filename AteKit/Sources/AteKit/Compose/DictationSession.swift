import Foundation

/// **One spell of dictation, stitched into words that are already there.**
///
/// A speech recogniser does not hand you the next word — it hands you *the whole utterance, again*,
/// every time it changes its mind ("was on real" becomes "was unreal" two hundred milliseconds
/// later). So the composer cannot append: it has to hold a region of the person's words that belongs
/// to the microphone and keep replacing exactly that region, leaving everything around it — words
/// typed before, a place token put there with the Place key, a score already minted — untouched.
///
/// This is that bookkeeping, as a value with no audio, no UIKit and no clock in it, because every way
/// it can be wrong is a way somebody's sentence gets mangled:
///
/// - **never duplicate.** The live region is replaced, never appended to.
/// - **never lose a correction.** Only the live region is ever written; if anything else has moved the
///   words under us the session re-anchors rather than writing over them (``reanchor(to:)``).
/// - **settle from the front.** Words the recogniser has stopped revising are *settled* (drawn in full
///   ink, `ComposerVoice.dc.html`); the tail it is still changing is volatile (drawn muted). The rule
///   is the longest common prefix of two consecutive transcripts, snapped back to a word boundary, and
///   it never goes backwards.
/// - **a spoken number is the same score token as a typed one** (design: "typing a number after a
///   dish, or saying one, becomes the same score token"). Promotion runs through the same
///   ``ScoreLiteral`` rule the keyboard uses, and only inside the settled region — promoting "4" while
///   the recogniser is still on its way to "4.5" would mint a score nobody gave, which design rule 7
///   forbids outright.
/// - **one undo.** Everything the microphone wrote is one contiguous span (``writtenSpan``), so the
///   text view's single `replace(_:withText:)` for it undoes as one operation.
public struct DictationSession: Hashable, Sendable {

    /// What one transcript did to the words.
    public struct Update: Hashable, Sendable {
        public var composition: EntryComposition
        /// Where the caret belongs afterwards: at the end of what has been said, in plain offsets.
        public var caretPlainOffset: Int
        /// Scores minted from spoken numbers by *this* transcript. One analytics event each, and the
        /// same event the keyboard's own promotion sends.
        public var promotedScores: [Rating]
    }

    /// Where the dictation was started, in plain offsets — the composer's caret.
    public private(set) var anchor: Int
    /// The space the dictation had to bring so its first word did not weld itself onto the last one
    /// typed, and the one it brought on the other side when it started mid-sentence.
    private var prefix = ""
    private var suffix = ""
    /// The region of the plain text the microphone owns: replaced whole on every transcript.
    private var live: TextSpan?
    /// What that region currently reads. The invariant that tells us whether anything else has edited
    /// the words while we were listening.
    private var liveText = ""
    /// How much of the transcript is **frozen**: already placed in the words and past a score token,
    /// so it is never replaced again. Revisions behind a pill would have to move the pill.
    private var frozen = 0
    /// How much of the transcript the recogniser has stopped revising. Monotonic.
    private var settled = 0
    private var previousTranscript = ""

    public private(set) var promotedScoreCount = 0

    public init(anchor: Int) {
        self.anchor = max(0, anchor)
    }

    // MARK: - Reading

    /// The whole region the microphone has written, spaces and any minted pill included — what one
    /// undo takes back out. Measured from the anchor to the end of the live region, so it still covers
    /// the words that were frozen behind a score token along the way.
    ///
    /// After a ``reanchor(to:)`` it covers only the region since: once something else has edited the
    /// words, what the microphone wrote is no longer one contiguous run and cannot honestly claim to be.
    public var writtenSpan: TextSpan {
        guard let live else { return TextSpan(location: anchor, length: 0) }
        return TextSpan(
            location: anchor,
            length: max(0, live.endLocation + suffix.utf16.count - anchor)
        )
    }

    /// Where the words stop being settled and start being the recogniser's current guess — the offset
    /// the voice screen draws muted from. `nil` while everything said so far has settled.
    public var volatilePlainStart: Int? {
        guard let live else { return nil }
        let start = live.location + max(0, min(settled, previousTranscript.utf16.count) - frozen)
        return start < live.endLocation ? start : nil
    }

    /// Words said in this spell of dictation — the transcript's own count, so it does not drift with
    /// however many partials arrived.
    public var wordCount: Int {
        previousTranscript.split(whereSeparator: \.isWhitespace).count
    }

    /// True while nothing has been said yet.
    public var isEmpty: Bool { live == nil || live?.length == 0 }

    // MARK: - Applying a transcript

    /// Stitches the recogniser's current transcript into the words.
    ///
    /// - Parameters:
    ///   - transcript: the **whole** utterance as the recogniser currently hears it.
    ///   - isFinal: the recogniser is done with this utterance — everything in it settles.
    ///   - composition: the words as they are now.
    public mutating func apply(
        transcript: String,
        isFinal: Bool = false,
        to composition: EntryComposition
    ) -> Update {
        var composition = composition
        // Something else edited the words while we were listening (a score slid, a place attached).
        // Rather than write over it, take everything said so far as placed and carry on at the end.
        if let live, composition.plainText(inPlainSpan: live) != liveText {
            reanchor(to: composition.plain.utf16.count)
        }

        settle(on: transcript, isFinal: isFinal)
        previousTranscript = transcript
        let tail = Self.dropping(frozen, from: transcript)
        composition = write(tail, into: composition)
        let promoted = promote(in: &composition, isFinal: isFinal)

        return Update(
            composition: composition,
            caretPlainOffset: (live ?? writtenSpan).endLocation,
            promotedScores: promoted
        )
    }

    /// The utterance ended: everything said settles, and a trailing number is promoted the way Done
    /// promotes one the person typed and never moved on from.
    public mutating func finish(to composition: EntryComposition) -> Update {
        apply(transcript: previousTranscript, isFinal: true, to: composition)
    }

    // MARK: - Pieces

    /// The longest common prefix of this transcript and the last one, snapped back to a word boundary
    /// — the words the recogniser has stopped changing. Never goes backwards: a word drawn in full
    /// ink does not go grey again, which would read as the app second-guessing itself.
    private mutating func settle(on transcript: String, isFinal: Bool) {
        let units = Array(transcript.utf16)
        guard isFinal == false else {
            settled = units.count
            return
        }
        let previous = Array(previousTranscript.utf16)
        var common = 0
        while common < units.count, common < previous.count, units[common] == previous[common] {
            common += 1
        }
        settled = max(settled, Self.wordBoundary(at: common, in: units))
    }

    /// Replaces the live region with the tail of the transcript — or opens the region, if this is the
    /// first thing said.
    private mutating func write(_ tail: String, into composition: EntryComposition) -> EntryComposition {
        if let live {
            let next = composition.applyingPlainEdit(replacing: live, with: tail)
            self.live = TextSpan(location: live.location, length: tail.utf16.count)
            liveText = tail
            return next
        }
        guard tail.isEmpty == false else { return composition }
        let units = Array(composition.plain.utf16)
        let at = min(anchor, units.count)
        anchor = at
        // A dictated run is a word, and it brings its own gaps — the same rule a token insertion
        // follows, and for the same reason: strip the structure and the sentence still reads.
        // …unless the tail already brought one. After a re-anchor the transcript's own space
        // between the last frozen word and the next is part of the tail, and adding a second is the
        // double space that used to turn up in the middle of somebody's sentence.
        let leadsWithSpace = tail.utf16.first.map(Self.whitespace.contains) ?? false
        prefix = at == 0 || leadsWithSpace || Self.whitespace.contains(units[at - 1]) ? "" : " "
        suffix = at < units.count && Self.whitespace.contains(units[at]) == false ? " " : ""
        let next = composition.applyingPlainEdit(
            replacing: TextSpan(location: at, length: 0),
            with: prefix + tail + suffix
        )
        live = TextSpan(location: at + prefix.utf16.count, length: tail.utf16.count)
        liveText = tail
        return next
    }

    /// **A spoken number becomes the same butter pill a typed one does.**
    ///
    /// Only inside the settled region: while the recogniser is still revising the tail, "4" is as
    /// likely to be on its way to "4.5" as to be a score, and minting the pill early would put a
    /// score in somebody's words that they never gave. The rule itself is ``ScoreLiteral`` — the
    /// keyboard's — reached through ``EntryComposition/pendingScoreLiteral(atDisplayOffset:)`` so the
    /// two paths cannot diverge, including its refusal to re-promote a pill that is already there.
    ///
    /// Everything up to and including a promoted number is then **frozen**: a later revision of the
    /// transcript can no longer reach it, because it would have to move a pill the person can already
    /// see (and might already have tapped).
    private mutating func promote(in composition: inout EntryComposition, isFinal: Bool) -> [Rating] {
        guard let region = live, region.length > 0 else { return [] }
        let settledEnd = min(
            region.location + max(0, min(settled, previousTranscriptLength) - frozen),
            region.endLocation
        )
        guard settledEnd > region.location else { return [] }

        // Every candidate found first, against one set of coordinates — the words as they are now.
        // Asked at exactly the offsets the keyboard asks at: **where the person moved on**, which is
        // the character after the digits. Asking at every offset instead would find the "4" inside a
        // "4.5" the recogniser is halfway through and mint a 4.0 nobody said.
        let units = Array(composition.plain.utf16)
        var candidates: [(span: TextSpan, rating: Rating)] = []
        for offset in (region.location + 1)...settledEnd where offset <= units.count {
            guard Self.isMoveOn(at: offset, in: units, isFinal: isFinal) else { continue }
            guard let found = composition.pendingScoreLiteral(
                atDisplayOffset: composition.displayOffset(forPlainOffset: offset)
            ), found.span.location >= region.location,
                candidates.contains(where: { $0.span.intersects(found.span) }) == false else { continue }
            candidates.append(found)
        }
        guard candidates.isEmpty == false else { return [] }

        var delta = 0
        var frozenTranscriptEnd = frozen
        var frozenPlainEnd = region.location
        for candidate in candidates {
            let span = TextSpan(location: candidate.span.location + delta, length: candidate.span.length)
            composition = composition.promoting(plainSpan: span, to: EntryToken(kind: .score(candidate.rating)))
            let printed = ScoreFormat.halfStep(candidate.rating.value).utf16.count
            // Transcript offsets come from the pre-promotion coordinates; plain ones from the post.
            frozenTranscriptEnd = frozen + candidate.span.endLocation - region.location
            frozenPlainEnd = span.location + printed
            delta += printed - span.length
        }

        promotedScoreCount += candidates.count
        frozen = frozenTranscriptEnd
        live = TextSpan(
            location: frozenPlainEnd,
            length: max(0, region.endLocation + delta - frozenPlainEnd)
        )
        liveText = composition.plainText(inPlainSpan: live ?? TextSpan(location: 0, length: 0))
        return candidates.map(\.rating)
    }

    private var previousTranscriptLength: Int { previousTranscript.utf16.count }

    /// The offsets the promotion rule is allowed to be asked about: where a character the person could
    /// only have "moved on" with sits — and, when the utterance has ended, the very end of the words,
    /// which is the same courtesy Done does for a number typed and never followed by anything.
    private static func isMoveOn(at offset: Int, in units: [UInt16], isFinal: Bool) -> Bool {
        guard offset > 0 else { return false }
        guard offset < units.count else { return isFinal }
        guard let scalar = Unicode.Scalar(units[offset]) else { return false }
        return ScoreLiteral.isMoveOn(
            String(Character(scalar)),
            afterDigit: units[offset - 1] >= 48 && units[offset - 1] <= 57
        )
    }

    /// Somebody else changed the words under us. Everything said so far stays exactly where it is,
    /// and the microphone starts a fresh region at the end — so nothing is overwritten and nothing is
    /// said twice.
    private mutating func reanchor(to plainOffset: Int) {
        frozen = previousTranscriptLength
        anchor = plainOffset
        prefix = ""
        suffix = ""
        live = nil
        liveText = ""
    }

    private static func dropping(_ count: Int, from transcript: String) -> String {
        let units = Array(transcript.utf16)
        guard count > 0 else { return transcript }
        guard count < units.count else { return "" }
        return String(decoding: units[count...], as: UTF16.self)
    }

    /// The largest offset no greater than `offset` that ends a whole word.
    private static func wordBoundary(at offset: Int, in units: [UInt16]) -> Int {
        if offset >= units.count { return units.count }
        var index = offset
        while index > 0, whitespace.contains(units[index]) == false { index -= 1 }
        return index
    }

    private static let whitespace: Set<UInt16> = [32, 9, 10]
}

extension EntryComposition {
    /// The plain characters a span covers — the invariant a dictation session checks before it writes
    /// over anything.
    public func plainText(inPlainSpan span: TextSpan) -> String {
        let units = Array(plain.utf16)
        guard span.location >= 0, span.endLocation <= units.count, span.length >= 0 else { return "" }
        return String(decoding: units[span.location..<span.endLocation], as: UTF16.self)
    }
}

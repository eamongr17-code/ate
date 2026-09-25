import Foundation
import Observation

/// What the microphone says.
public enum VoiceTranscriberEvent: Sendable, Equatable {
    /// The **whole utterance so far**, as the recogniser currently hears it — not the next word. It
    /// re-sends everything every time it changes its mind, which is what ``DictationSession`` exists to
    /// absorb. `isFinal` means the recogniser is done with this utterance; the next transcript starts
    /// from nothing.
    case transcript(String, isFinal: Bool)
    /// How loud the room is, 0…1 — the waveform's bars.
    case level(Float)
    /// Listening ended on its own — the recogniser gave up for good, or the audio was taken away.
    case stopped(VoiceDenialReason?)
}

/// **The dictation seam.** A simulator has no microphone, and the whole transcript path has to be
/// drivable without one — so the recogniser is a protocol, and the app's is one implementation of it.
@MainActor
public protocol VoiceTranscribing: AnyObject {
    /// Asks for everything it needs, once. `nil` when it can listen.
    func authorize() async -> VoiceDenialReason?
    /// Starts listening. The stream ends when ``stop()`` is called, or when listening stops by itself.
    func start() -> AsyncStream<VoiceTranscriberEvent>
    func stop()
}

/// The words dictation writes into — the composer. A protocol so the controller can be tested without
/// the app's model.
@MainActor
public protocol DictationTarget: AnyObject {
    var composition: EntryComposition { get }
    /// Where the caret is in the plain words — where dictation starts.
    var caretPlainOffset: Int { get }
    /// One transcript's worth of words.
    func applyDictation(_ update: DictationSession.Update)
    /// Dictation ended: the editor takes everything said in one edit.
    func commitDictation(refocus: Bool)
}

/// **One spell of the microphone being open**: permission, listening, the transcripts going into the
/// words, and stopping — with every way of stopping ending in exactly one place.
///
/// The lifecycle is the risky part (a microphone left running with nobody looking at it is a privacy
/// bug, not a glitch), so it lives here, UI-free, where it is tested.
@MainActor
@Observable
public final class DictationController {
    public enum State: Equatable, Sendable {
        /// Asking for the microphone, or waiting for the first buffer.
        case starting
        case listening
        /// Refused or unavailable. The design draws no explanation; the key goes to Settings.
        case denied(VoiceDenialReason)
        /// Stopped — by a key, by the screen closing, or by the recogniser giving up.
        case stopped
    }

    public private(set) var state: State = .starting
    /// A rolling history of how loud the room has been, newest last.
    public private(set) var levels: [Float] = []
    /// Where the words stop being settled — the tail drawn muted.
    public private(set) var volatilePlainStart: Int?

    /// How many bars the artboard draws; the history is kept at exactly that length.
    public static let barCount = 19

    private let target: any DictationTarget
    private let transcriber: any VoiceTranscribing
    private let analytics: AnalyticsRecorder
    private var session: DictationSession
    private var listening: Task<Void, Never>?
    private var wordsSaid = 0
    private var tokensMinted = 0
    private var hasStopped = false
    private var isAuthorizing = false
    /// The refusal already reported. Coming back from Settings still refused is the same denial, not
    /// a new one — `entry_voice_denied` counts people turned away, not trips to Settings.
    private var reportedDenial: VoiceDenialReason?

    public init(
        target: any DictationTarget,
        transcriber: any VoiceTranscribing,
        analytics: @escaping AnalyticsRecorder
    ) {
        self.target = target
        self.transcriber = transcriber
        self.analytics = analytics
        self.session = DictationSession(anchor: target.caretPlainOffset)
    }

    // MARK: - Listening

    /// Asks, then listens. **Stopping while the permission prompt is up wins**: the answer arriving
    /// after the screen has closed must never open the microphone, because nothing would ever close it.
    public func start() async {
        guard state == .starting, listening == nil, hasStopped == false, isAuthorizing == false else { return }
        isAuthorizing = true
        let denial = await transcriber.authorize()
        isAuthorizing = false
        guard hasStopped == false, Task.isCancelled == false else { return }
        if let denial {
            state = .denied(denial)
            if denial != reportedDenial {
                reportedDenial = denial
                analytics(EntryEvents.voiceDenied(reason: denial))
            }
            return
        }
        reportedDenial = nil
        state = .listening
        analytics(EntryEvents.voiceStarted())
        session = DictationSession(anchor: target.caretPlainOffset)
        let stream = transcriber.start()
        listening = Task { [weak self] in
            for await event in stream {
                guard let self, self.hasStopped == false else { return }
                self.receive(event)
            }
        }
    }

    /// Back from Settings: ask again, and listen if the answer has changed.
    public func retry() async {
        guard case .denied = state, hasStopped == false else { return }
        state = .starting
        await start()
    }

    private func receive(_ event: VoiceTranscriberEvent) {
        switch event {
        case .level(let level):
            levels.append(level)
            if levels.count > Self.barCount { levels.removeFirst(levels.count - Self.barCount) }
        case .transcript(let text, let isFinal):
            apply(text, isFinal: isFinal)
        case .stopped(let reason):
            // The recogniser gave up for good. Whatever was said stays in the words; the key shows
            // the refused state rather than a pulse that is no longer listening to anything.
            finishSession(refocus: false)
            listening = nil
            transcriber.stop()
            if let reason {
                state = .denied(reason)
                analytics(EntryEvents.voiceDenied(reason: reason))
            } else {
                state = .stopped
            }
        }
    }

    private func apply(_ transcript: String, isFinal: Bool) {
        let update = session.apply(transcript: transcript, isFinal: isFinal, to: target.composition)
        target.applyDictation(update)
        volatilePlainStart = session.volatilePlainStart
        for _ in update.promotedScores {
            analytics(EntryEvents.scoreTokenCreated(source: .dictation))
        }
        guard isFinal else { return }
        // The recogniser closed that utterance; the next transcripts start from nothing.
        wordsSaid += session.wordCount
        tokensMinted += session.promotedScoreCount
        session = DictationSession(anchor: update.caretPlainOffset)
        volatilePlainStart = nil
    }

    // MARK: - Stopping

    /// The stop key, Done, the close key and the screen going away all end here. Safe to call at any
    /// point — including while the permission prompt is still up — and more than once.
    public func stop(refocus: Bool) {
        guard hasStopped == false else { return }
        hasStopped = true
        listening?.cancel()
        listening = nil
        transcriber.stop()
        finishSession(refocus: refocus)
        state = .stopped
    }

    /// Whatever was still being heard settles into the words, and the editor takes the lot.
    private func finishSession(refocus: Bool) {
        guard state == .listening else { return }
        let update = session.finish(to: target.composition)
        target.applyDictation(update)
        for _ in update.promotedScores {
            analytics(EntryEvents.scoreTokenCreated(source: .dictation))
        }
        target.commitDictation(refocus: refocus)
        volatilePlainStart = nil
        let words = wordsSaid + session.wordCount
        let tokens = tokensMinted + session.promotedScoreCount
        // Counted once: a retry after the recogniser gave up starts its own tally.
        wordsSaid = 0
        tokensMinted = 0
        session = DictationSession(anchor: update.caretPlainOffset)
        guard words > 0 else { return }
        analytics(EntryEvents.voiceCommitted(wordCount: words, tokenCount: tokens))
    }
}

/// **When a recognition task fails, how long to wait before the next one — and when to give up.**
///
/// The recogniser ends a task after every pause (a normal `isFinal`) and the app starts a fresh one so
/// dictation does not stop mid-thought. An *error* is different: restarting straight away on one that
/// will just happen again is a hot loop. So errors back off, a run of them gives up, and anything the
/// recogniser actually hears resets the count.
public struct RecognitionRestartPolicy: Sendable, Equatable {
    public static let maximumConsecutiveFailures = 3
    /// Seconds, per consecutive failure: 0.25, 0.5, 1.
    public static let backoff: [Double] = [0.25, 0.5, 1]

    public private(set) var consecutiveFailures = 0

    public init() {}

    public enum Decision: Equatable, Sendable {
        case restart(afterSeconds: Double)
        case giveUp
    }

    /// A task ended. `failed` is whether it ended with an error.
    public mutating func taskEnded(failed: Bool) -> Decision {
        guard failed else {
            consecutiveFailures = 0
            return .restart(afterSeconds: 0)
        }
        consecutiveFailures += 1
        guard consecutiveFailures <= Self.maximumConsecutiveFailures else { return .giveUp }
        return .restart(afterSeconds: Self.backoff[consecutiveFailures - 1])
    }

    /// The recogniser heard something: it is working.
    public mutating func heardSomething() {
        consecutiveFailures = 0
    }
}

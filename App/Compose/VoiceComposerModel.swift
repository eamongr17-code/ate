import AteKit
import Observation
import SwiftUI

/// **The composer with the microphone open** (`ComposerVoice.dc.html`): what is being heard, what has
/// settled into the words, and nothing else.
///
/// It does not own a composition. The words belong to ``ComposerModel`` the whole time — the same value
/// the keyboard edits, the same draft on disk, the same tokens — and this only pushes each transcript
/// into it through ``DictationSession``. That is what makes "saying 4.5 is the same pill as typing it"
/// true by construction rather than by a second implementation.
@MainActor
@Observable
final class VoiceComposerModel {
    enum State: Equatable {
        /// Asking for the microphone, or waiting for the first buffer.
        case starting
        case listening
        /// The design draws no explanation, so neither do we: the control is simply not live, and
        /// tapping it goes to Settings.
        case denied(VoiceDenialReason)
    }

    private(set) var state: State = .starting
    /// A rolling history of how loud the room has been, newest last — the waveform's bars.
    private(set) var levels: [Float] = []
    /// Where the words stop being settled and start being the recogniser's current guess. The tail is
    /// drawn muted, as the artboard draws it.
    private(set) var volatilePlainStart: Int?

    /// The words, and everything else the composer knows about them.
    let composer: ComposerModel

    private let transcriber: any VoiceTranscribing
    private let analytics: AnalyticsRecorder
    private var session: DictationSession
    private var listening: Task<Void, Never>?
    /// Everything said in this spell of dictation, across however many utterances the recogniser chose
    /// to break it into.
    private var wordsSaid = 0
    private var tokensMinted = 0
    private var hasStopped = false

    /// How many bars the artboard draws. The history is kept at exactly that length, so the row is the
    /// same width whether somebody has been talking for one second or thirty.
    static let barCount = 19

    init(
        composer: ComposerModel,
        transcriber: any VoiceTranscribing,
        analytics: @escaping AnalyticsRecorder
    ) {
        self.composer = composer
        self.transcriber = transcriber
        self.analytics = analytics
        self.session = DictationSession(anchor: composer.caretPlainOffset)
    }

    // MARK: - Listening

    func start() async {
        guard state == .starting, listening == nil else { return }
        if let reason = await transcriber.authorize() {
            state = .denied(reason)
            analytics(EntryEvents.voiceDenied(reason: reason))
            return
        }
        state = .listening
        analytics(EntryEvents.voiceStarted())
        session = DictationSession(anchor: composer.caretPlainOffset)
        let stream = transcriber.start()
        listening = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                receive(event)
            }
        }
    }

    /// Back from Settings: ask again, and listen if the answer has changed.
    func retry() async {
        guard case .denied = state, hasStopped == false else { return }
        guard await transcriber.authorize() == nil else { return }
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
            if let reason, state == .starting || session.isEmpty {
                state = .denied(reason)
                analytics(EntryEvents.voiceDenied(reason: reason))
            }
        }
    }

    private func apply(_ transcript: String, isFinal: Bool) {
        let update = session.apply(transcript: transcript, isFinal: isFinal, to: composer.composition)
        composer.applyDictation(update)
        volatilePlainStart = session.volatilePlainStart
        // A number said out loud is the same event a number typed sends, with its own source — so the
        // funnel can compare the keyboard's shortcut with the at-the-table path.
        for _ in update.promotedScores {
            analytics(EntryEvents.scoreTokenCreated(source: .dictation))
        }
        guard isFinal else { return }
        // The recogniser closed that utterance; the next transcripts start from nothing. Carry the
        // counts and open a fresh region at the end of what was said.
        wordsSaid += session.wordCount
        tokensMinted += session.promotedScoreCount
        session = DictationSession(anchor: update.caretPlainOffset)
        volatilePlainStart = nil
    }

    // MARK: - Stopping

    /// The stop key, Done, and the close key all end up here: the microphone goes off, whatever was
    /// still being heard settles into the words, and the editor takes the lot in one edit.
    ///
    /// - Parameter refocus: whether the composer's keyboard should come back — true for the stop key,
    ///   false when the entry is being saved or the composer is being closed.
    func stop(refocus: Bool) {
        guard hasStopped == false else { return }
        hasStopped = true
        listening?.cancel()
        listening = nil
        transcriber.stop()
        guard case .listening = state else { return }
        let update = session.finish(to: composer.composition)
        composer.applyDictation(update)
        for _ in update.promotedScores {
            analytics(EntryEvents.scoreTokenCreated(source: .dictation))
        }
        composer.commitDictation(refocus: refocus)
        volatilePlainStart = nil
        let words = wordsSaid + session.wordCount
        guard words > 0 else { return }
        analytics(EntryEvents.voiceCommitted(
            wordCount: words,
            tokenCount: tokensMinted + session.promotedScoreCount
        ))
    }

    /// The refused state's one action. No copy, per design rule 1 — the control just isn't live, and
    /// this is where it goes.
    var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
}

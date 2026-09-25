import AteKit
import AVFoundation
import Speech

/// What the microphone says.
enum VoiceTranscriberEvent: Sendable {
    /// The **whole utterance so far**, as the recogniser currently hears it — not the next word. It
    /// re-sends everything every time it changes its mind, which is what ``DictationSession`` exists to
    /// absorb. `isFinal` means the recogniser is done with this utterance; the next transcript starts
    /// from nothing.
    case transcript(String, isFinal: Bool)
    /// How loud the room is, 0…1. The only reason the audio tap belongs to us rather than to the
    /// recogniser: `ComposerVoice.dc.html` draws a live waveform, and no speech API reports level.
    case level(Float)
    /// Listening ended on its own — the recogniser gave up, or the audio session was taken away.
    case stopped(VoiceDenialReason?)
}

/// **The dictation seam.** A protocol with three methods, because a simulator has no microphone and
/// the whole transcript path — partial results, revisions, a number becoming a pill — has to be
/// drivable without one (`ComposerDebugLaunch.fakesDictation`).
@MainActor
protocol VoiceTranscribing: AnyObject {
    /// Asks for everything it needs, once. `nil` when it can listen.
    func authorize() async -> VoiceDenialReason?
    /// Starts listening. The stream ends when ``stop()`` is called, or when listening stops by itself.
    func start() -> AsyncStream<VoiceTranscriberEvent>
    func stop()
}

/// **On-device dictation through the Speech framework.**
///
/// Two deliberate choices:
///
/// - **`requiresOnDeviceRecognition` wherever the phone supports it.** Somebody dictating a review at
///   a table is saying where they are and who they are with; that does not need to leave the phone.
///   The flag is honest about the fallback — when the locale has no on-device model, recognition is
///   Apple's server, which is what the usage description says.
/// - **our own audio tap.** The recogniser takes buffers; the waveform needs their amplitude. One tap
///   feeds both, so the bars move with the voice rather than on a timer.
///
/// The recogniser finalises an utterance after a pause and stops. That would end dictation in the
/// middle of somebody thinking, so a finished task is replaced with a fresh request while the engine
/// keeps running: the caller sees `isFinal` and then transcripts starting from nothing again.
@MainActor
final class SystemVoiceTranscriber: VoiceTranscribing {
    private let recogniser = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sink: BufferSink?
    private var continuation: AsyncStream<VoiceTranscriberEvent>.Continuation?
    private var isListening = false

    func authorize() async -> VoiceDenialReason? {
        // `isAvailable` is asked *after* authorisation, not before: an unauthorised recogniser reports
        // itself unavailable, and answering "unavailable" to somebody who has never been asked would
        // take the microphone away without ever offering it.
        guard let recogniser else { return .unavailable }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return .speech }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else { return .microphone }
        return recogniser.isAvailable ? nil : .unavailable
    }

    func start() -> AsyncStream<VoiceTranscriberEvent> {
        let (stream, continuation) = AsyncStream<VoiceTranscriberEvent>.makeStream()
        self.continuation = continuation
        isListening = true
        do {
            try startAudio(sending: continuation)
            listen(sending: continuation)
        } catch {
            continuation.yield(.stopped(.unavailable))
            continuation.finish()
            isListening = false
        }
        return stream
    }

    func stop() {
        isListening = false
        task?.finish()
        task = nil
        request?.endAudio()
        request = nil
        sink?.use(nil)
        sink = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio

    private func startAudio(sending continuation: AsyncStream<VoiceTranscriberEvent>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        // `.measurement` turns off the processing that would flatten the level the waveform draws.
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A simulator, or a phone whose input has been taken away, reports no channels — and
        // `installTap` on that raises rather than throws.
        guard format.channelCount > 0 else { throw VoiceTranscriberError.noInput }

        let sink = BufferSink(continuation: continuation)
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.receive(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// One recognition task, and its replacement when the recogniser decides the utterance is over.
    private func listen(sending continuation: AsyncStream<VoiceTranscriberEvent>.Continuation) {
        guard let recogniser, isListening else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // "was unreal, 4.5" — the comma is what makes the number a score rather than part of the
        // sentence, and `ScoreLiteral` reads it exactly as it reads a typed one.
        request.addsPunctuation = true
        if recogniser.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        sink?.use(request)
        // The handler arrives on the recogniser's own queue, so the transcript is read out of the
        // result there — `SFSpeechRecognitionResult` cannot cross an isolation boundary — and only the
        // words themselves hop to the main actor.
        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let isOver = isFinal || error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let transcript {
                    continuation.yield(.transcript(transcript, isFinal: isFinal))
                }
                guard isOver else { return }
                // The utterance ended, or the task failed. Keep the microphone open: a pause in the
                // middle of a sentence is not somebody finishing.
                self.task = nil
                self.request?.endAudio()
                self.request = nil
                self.listen(sending: continuation)
            }
        }
    }

    /// The audio thread's end of the tap. `@unchecked Sendable` and deliberate: a realtime callback
    /// cannot hop to an actor, and all this does is hand the buffer to the recogniser (which documents
    /// `append` as callable from the audio thread) and yield a number to a `Sendable` continuation.
    ///
    /// The request it appends to is swapped from the main actor every time the recogniser finalises an
    /// utterance, so the one piece of shared mutable state is behind a lock. Reaching for
    /// `MainActor.assumeIsolated` here instead would be a crash, not a shortcut: the audio thread is
    /// not the main actor and saying so does not make it one.
    private final class BufferSink: @unchecked Sendable {
        private let continuation: AsyncStream<VoiceTranscriberEvent>.Continuation
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?

        init(continuation: AsyncStream<VoiceTranscriberEvent>.Continuation) {
            self.continuation = continuation
        }

        func use(_ request: SFSpeechAudioBufferRecognitionRequest?) {
            lock.withLock { self.request = request }
        }

        func receive(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { request }?.append(buffer)
            continuation.yield(.level(Self.level(of: buffer)))
        }

        /// Root mean square, in a rough 0…1 the bars can be drawn from: −50 dB is a quiet room, 0 dB
        /// is clipping.
        private static func level(of buffer: AVAudioPCMBuffer) -> Float {
            guard let channel = buffer.floatChannelData?[0] else { return 0 }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return 0 }
            var sum: Float = 0
            for index in 0..<count {
                sum += channel[index] * channel[index]
            }
            let decibels = 20 * log10(max(sqrt(sum / Float(count)), .leastNormalMagnitude))
            return min(1, max(0, (decibels + 50) / 50))
        }
    }
}

enum VoiceTranscriberError: Error {
    case noInput
}

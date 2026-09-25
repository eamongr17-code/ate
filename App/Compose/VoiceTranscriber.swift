import AteKit
import AVFoundation
import Speech

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
    /// Which recognition task is current; a late callback from a replaced one is ignored.
    private var generation = 0
    private var restarts = RecognitionRestartPolicy()
    private var restartWork: Task<Void, Never>?

    func authorize() async -> VoiceDenialReason? {
        // `isAvailable` is asked *after* authorisation, not before: an unauthorised recogniser reports
        // itself unavailable, and answering "unavailable" to somebody who has never been asked would
        // take the microphone away without ever offering it.
        guard let recogniser else { return .unavailable }
        guard await Self.speechAuthorization() == .authorized else { return .speech }
        guard await Self.microphonePermission() else { return .microphone }
        return recogniser.isAvailable ? nil : .unavailable
    }

    // MARK: - Callbacks that arrive off the main thread
    //
    // **Every closure handed to Speech or AVFAudio is built in a `nonisolated` function.** A closure
    // written inside this `@MainActor` class inherits main-actor isolation, and Swift 6 checks that at
    // runtime: the permission handlers and the audio tap are called on the framework's own queues, so
    // the first real use of the mic was `swift_task_reportUnexpectedExecutor` — a crash. Built here,
    // they are `@Sendable` and isolated to nothing, and the compiler refuses any touch of main-actor
    // state inside them; anything that needs the main actor hops there explicitly.

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization(OffMainCallback.resuming(continuation))
        }
    }

    nonisolated private static func microphonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission(completionHandler: OffMainCallback.resuming(continuation))
        }
    }

    nonisolated private static func isSilence(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    nonisolated private static func tap(_ sink: BufferSink) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in sink.receive(buffer) }
    }

    /// The recogniser's result handler: reads what it needs on the recogniser's queue — a result
    /// cannot cross an isolation boundary — and hops to the main actor with plain values only.
    nonisolated private static func resultHandler(
        for transcriber: SystemVoiceTranscriber,
        generation: Int
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak transcriber] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            // "No speech detected" is silence, not a fault: somebody thinking. Counting it would give
            // up on a person for pausing three times.
            let failed = error.map { Self.isSilence($0) == false } ?? false
            Task { @MainActor [weak transcriber] in
                transcriber?.received(
                    transcript: transcript, isFinal: isFinal, failed: failed, generation: generation
                )
            }
        }
    }

    func start() -> AsyncStream<VoiceTranscriberEvent> {
        let (stream, continuation) = AsyncStream<VoiceTranscriberEvent>.makeStream()
        self.continuation = continuation
        isListening = true
        restarts = RecognitionRestartPolicy()
        do {
            try startAudio(sending: continuation)
            listen()
        } catch {
            continuation.yield(.stopped(.unavailable))
            continuation.finish()
            isListening = false
        }
        return stream
    }

    func stop() {
        isListening = false
        restartWork?.cancel()
        restartWork = nil
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink))
        engine.prepare()
        try engine.start()
    }

    /// One recognition task. Its replacement is decided in ``received(transcript:isFinal:failed:generation:)``.
    private func listen() {
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
        generation += 1
        task = recogniser.recognitionTask(
            with: request,
            resultHandler: Self.resultHandler(for: self, generation: generation)
        )
    }

    /// On the main actor, with plain values. A task that has been replaced is ignored.
    private func received(transcript: String?, isFinal: Bool, failed: Bool, generation: Int) {
        guard isListening, generation == self.generation else { return }
        if let transcript, transcript.isEmpty == false {
            restarts.heardSomething()
            continuation?.yield(.transcript(transcript, isFinal: isFinal))
        }
        guard isFinal || failed || transcript == nil else { return }
        // The utterance ended, or the task failed. A pause mid-sentence is not somebody finishing, so
        // a fresh task follows — straight away after a pause, backing off after an error, and not at
        // all after a run of errors: that is the recogniser not working, and the screen says so.
        task = nil
        request?.endAudio()
        request = nil
        switch restarts.taskEnded(failed: failed && isFinal == false) {
        case .restart(let seconds) where seconds == 0:
            listen()
        case .restart(let seconds):
            restartWork = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard Task.isCancelled == false else { return }
                self?.listen()
            }
        case .giveUp:
            continuation?.yield(.stopped(.unavailable))
            stop()
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

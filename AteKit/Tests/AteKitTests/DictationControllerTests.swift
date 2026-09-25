import Foundation
import Testing
@testable import AteKit

/// **The microphone's lifecycle.** A microphone left open with nobody looking at it is a privacy bug,
/// so every way of stopping — including stopping while the permission prompt is still up — is pinned.
@MainActor
@Suite("Dictation controller — the microphone opens once and always closes")
struct DictationControllerTests {

    final class Target: DictationTarget {
        var composition = EntryComposition()
        var caretPlainOffset = 0
        var commits = 0
        func applyDictation(_ update: DictationSession.Update) {
            composition = update.composition
            caretPlainOffset = update.caretPlainOffset
        }
        func commitDictation(refocus: Bool) { commits += 1 }
    }

    /// A recogniser whose permission answer is held until the test releases it.
    final class Transcriber: VoiceTranscribing {
        var denial: VoiceDenialReason?
        var startCount = 0
        var stopCount = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var isGated: Bool
        private var continuation: AsyncStream<VoiceTranscriberEvent>.Continuation?

        init(gated: Bool = false) { isGated = gated }

        func authorize() async -> VoiceDenialReason? {
            if isGated { await withCheckedContinuation { gate = $0 } }
            return denial
        }

        func releaseAuthorization() {
            isGated = false
            gate?.resume()
            gate = nil
        }

        var isWaitingForAuthorization: Bool { gate != nil }

        func start() -> AsyncStream<VoiceTranscriberEvent> {
            startCount += 1
            let (stream, continuation) = AsyncStream<VoiceTranscriberEvent>.makeStream()
            self.continuation = continuation
            return stream
        }

        func stop() {
            stopCount += 1
            continuation?.finish()
        }

        func send(_ event: VoiceTranscriberEvent) { continuation?.yield(event) }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AnalyticsEvent] = []
        var names: [String] { lock.withLock { events.map(\.name) } }
        var all: [AnalyticsEvent] { lock.withLock { events } }
        func record(_ event: AnalyticsEvent) { lock.withLock { events.append(event) } }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("closing while the permission prompt is up never opens the microphone")
    func stopDuringAuthorizationWins() async {
        let transcriber = Transcriber(gated: true)
        let recorder = Recorder()
        let controller = DictationController(
            target: Target(), transcriber: transcriber, analytics: recorder.record
        )
        let starting = Task { await controller.start() }
        await settle()
        #expect(transcriber.isWaitingForAuthorization)

        controller.stop(refocus: false)
        transcriber.releaseAuthorization()
        await starting.value

        #expect(transcriber.startCount == 0)
        #expect(controller.state == .stopped)
        #expect(recorder.names.contains("entry_voice_started") == false)
    }

    @Test("a cancelled start does not open the microphone either")
    func cancelledStartDoesNotListen() async {
        let transcriber = Transcriber(gated: true)
        let controller = DictationController(
            target: Target(), transcriber: transcriber, analytics: { _ in }
        )
        let starting = Task { await controller.start() }
        await settle()
        starting.cancel()
        transcriber.releaseAuthorization()
        await starting.value
        #expect(transcriber.startCount == 0)
    }

    @Test("a refusal is the denied state and one event, and nothing listens")
    func denied() async {
        let transcriber = Transcriber()
        transcriber.denial = .microphone
        let recorder = Recorder()
        let controller = DictationController(
            target: Target(), transcriber: transcriber, analytics: recorder.record
        )
        await controller.start()
        #expect(controller.state == .denied(.microphone))
        #expect(transcriber.startCount == 0)
        #expect(recorder.names == ["entry_voice_denied"])
    }

    @Test("coming back from Settings still refused is the same denial — one event, not one per return")
    func deniedOncePerDenial() async {
        let transcriber = Transcriber()
        transcriber.denial = .speech
        let recorder = Recorder()
        let controller = DictationController(
            target: Target(), transcriber: transcriber, analytics: recorder.record
        )
        await controller.start()
        await controller.retry()
        await controller.retry()
        #expect(controller.state == .denied(.speech))
        #expect(recorder.names == ["entry_voice_denied"])

        // A different refusal is a different denial.
        transcriber.denial = .microphone
        await controller.retry()
        #expect(recorder.names == ["entry_voice_denied", "entry_voice_denied"])

        // Allowed at last: it listens.
        transcriber.denial = nil
        await controller.retry()
        #expect(controller.state == .listening)
        #expect(transcriber.startCount == 1)
        controller.stop(refocus: false)
    }

    @Test("words said go into the target, and stopping commits them once")
    func transcriptsAndStop() async {
        let transcriber = Transcriber()
        let target = Target()
        let recorder = Recorder()
        let controller = DictationController(
            target: target, transcriber: transcriber, analytics: recorder.record
        )
        await controller.start()
        #expect(controller.state == .listening)
        transcriber.send(.transcript("the ragù was unreal, 4.5", isFinal: false))
        await settle()
        #expect(target.composition.plain == "the ragù was unreal, 4.5")

        controller.stop(refocus: true)
        controller.stop(refocus: true)
        #expect(target.commits == 1)
        #expect(transcriber.stopCount == 1)
        #expect(target.composition.scores == [Rating(exactly: 4.5)])
        let committed = recorder.all.first { $0.name == "entry_voice_committed" }
        #expect(committed?.parameters["word_count"] == "5")
        #expect(committed?.parameters["token_count"] == "1")
    }

    @Test("the recogniser giving up for good is the unavailable state, with the words kept")
    func recogniserGivesUp() async {
        let transcriber = Transcriber()
        let target = Target()
        let recorder = Recorder()
        let controller = DictationController(
            target: target, transcriber: transcriber, analytics: recorder.record
        )
        await controller.start()
        transcriber.send(.transcript("the ragù", isFinal: false))
        transcriber.send(.stopped(.unavailable))
        await settle()
        #expect(controller.state == .denied(.unavailable))
        #expect(target.composition.plain == "the ragù")
        #expect(target.commits == 1)
        #expect(recorder.names.contains("entry_voice_denied"))
        #expect(transcriber.stopCount == 1)
    }
}

@Suite("Recognition restarts — back off, then give up")
struct RecognitionRestartPolicyTests {

    @Test("a pause ending an utterance restarts at once and is never counted as a failure")
    func normalEndRestarts() {
        var policy = RecognitionRestartPolicy()
        for _ in 0..<10 {
            #expect(policy.taskEnded(failed: false) == .restart(afterSeconds: 0))
        }
    }

    @Test("errors back off, and a run of them gives up instead of looping")
    func errorsBackOffThenGiveUp() {
        var policy = RecognitionRestartPolicy()
        #expect(policy.taskEnded(failed: true) == .restart(afterSeconds: 0.25))
        #expect(policy.taskEnded(failed: true) == .restart(afterSeconds: 0.5))
        #expect(policy.taskEnded(failed: true) == .restart(afterSeconds: 1))
        #expect(policy.taskEnded(failed: true) == .giveUp)
    }

    @Test("hearing something resets the count")
    func heardSomethingResets() {
        var policy = RecognitionRestartPolicy()
        _ = policy.taskEnded(failed: true)
        _ = policy.taskEnded(failed: true)
        policy.heardSomething()
        #expect(policy.taskEnded(failed: true) == .restart(afterSeconds: 0.25))
    }
}

#if DEBUG
import AteKit
import Foundation

/// **A microphone for a machine that hasn't got one.**
///
/// The simulator has no audio input, so the whole transcript path — a partial result growing, the
/// recogniser changing its mind, a spoken number settling into a butter pill, the waveform moving —
/// cannot be driven there at all without a stand-in. This is that stand-in: it replays a scripted
/// utterance the way a recogniser actually behaves (**the whole utterance, again**, every time), so what
/// is photographed on a simulator is the real screen doing the real stitching.
///
/// Debug only, behind a launch argument, and never reachable in a build anybody runs.
@MainActor
final class FakeVoiceTranscriber: VoiceTranscribing {
    /// Set to refuse, for the state the design draws no copy for.
    var denial: VoiceDenialReason?

    private var continuation: AsyncStream<VoiceTranscriberEvent>.Continuation?
    private var work: Task<Void, Never>?

    /// `ComposerVoice.dc.html`'s own sentence, in the chunks a recogniser hands it over in — including
    /// one revision ("was on real" → "was unreal") and the number that becomes the pill.
    static let script = [
        "The tagliatelle",
        "The tagliatelle al ragu",
        "The tagliatelle al ragù was on real",
        "The tagliatelle al ragù was unreal, 4.5",
        "The tagliatelle al ragù was unreal, 4.5 rich, glossy,",
        "The tagliatelle al ragù was unreal, 4.5 rich, glossy, gone in about four minutes "
            + "and the tiramisu was"
    ]

    func authorize() async -> VoiceDenialReason? { denial }

    func start() -> AsyncStream<VoiceTranscriberEvent> {
        let (stream, continuation) = AsyncStream<VoiceTranscriberEvent>.makeStream()
        self.continuation = continuation
        work = Task { [continuation] in
            var step = 0
            var tick = 0
            // A loudness that reads as a voice rather than a sine wave: the bars have to look like
            // somebody talking for the screenshot to be worth anything.
            let levels: [Float] = [0.42, 0.74, 0.31, 0.88, 0.55, 0.19, 0.66, 0.95, 0.38, 0.72, 0.27]
            while Task.isCancelled == false, step < Self.script.count {
                try? await Task.sleep(for: .milliseconds(120))
                continuation.yield(.level(levels[tick % levels.count]))
                tick += 1
                guard tick.isMultiple(of: 7) else { continue }
                continuation.yield(.transcript(Self.script[step], isFinal: false))
                step += 1
            }
        }
        return stream
    }

    func stop() {
        work?.cancel()
        work = nil
        continuation?.finish()
        continuation = nil
    }
}
#endif

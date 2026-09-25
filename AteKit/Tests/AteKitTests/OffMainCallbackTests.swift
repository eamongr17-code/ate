import Foundation
import Testing
@testable import AteKit

/// Pins the fix for the first-mic-use crash: a permission handler **built on the main actor** and
/// **called on a background queue** — what `SFSpeechRecognizer.requestAuthorization` and
/// `AVAudioApplication.requestRecordPermission` do. The runtime trap itself only fires across a
/// preconcurrency framework boundary, which a macOS test host cannot reach without a TCC prompt; the
/// other half of the guard is compile-time — the helper is `nonisolated` and returns `@Sendable`.
@MainActor
@Suite("Framework callbacks that arrive off the main thread")
struct OffMainCallbackTests {

    @Test("a continuation handler made on the main actor survives being called from a background queue")
    func survivesBackgroundCallback() async {
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let handler = OffMainCallback.resuming(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(Thread.isMainThread == false)
                handler(true)
            }
        }
        #expect(answer)
    }
}

import AteKit
import SwiftUI

extension View {
    /// **A write that did not happen, said once.** Report, block, a correction, a new place, sign-in,
    /// the avatar: every one of them used to fail in silence, which is worse than failing. This is
    /// the same native alert Settings already uses for a refused delete — one line, OK, nothing else
    /// (design rule 1) — so every failure in the app reads the same way.
    ///
    /// Counted as `action_failed` the moment it is shown, with the action it was about.
    func ateFailureAlert(_ failure: Binding<ActionFailure?>, analytics: AnalyticsRecorder? = nil) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if $0 == false { failure.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: failure.wrappedValue) { _, shown in
            guard let shown else { return }
            (analytics ?? AteTelemetry.record)(RecoveryEvents.actionFailed(shown))
        }
    }
}

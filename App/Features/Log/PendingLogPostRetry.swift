import AteKit
import SwiftUI

/// Runs §6.4's one-shot auto-retry when the app comes to the foreground.
///
/// The draft carries the flag; this is what reads it. Attached once, at the app's root, because the
/// sitting it rescues no longer has a sheet — the person left, believing their dishes were saved
/// (they were told exactly that). This is the promise being kept.
///
/// "One-shot per foreground" is enforced twice: the modifier arms itself only on a real
/// background→active transition, and ``LogPostRetryRunner`` refuses to run while a run is in flight.
/// A retry is idempotent anyway (client ids; a 23505 reads as success), so the cost of a stray extra
/// call is a round trip, never a duplicate review.
struct PendingLogPostRetry: ViewModifier {
    let services: LogServices
    /// Fired when a pending sitting finally posts. Today the host refreshes the feed, which is where
    /// the recovered reviews appear. The §6.4 "quiet notice in Diary" lands when Diary does.
    let onCompleted: (LogPostRetryResult) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var runner: LogPostRetryRunner?
    @State private var isArmed = true

    func body(content: Content) -> some View {
        content
            // Launch counts as a foreground: the common case is the app being killed while offline.
            .task { await run() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    Task { await run() }
                default:
                    isArmed = true
                }
            }
    }

    private func run() async {
        guard isArmed else { return }
        isArmed = false
        let runner = runner ?? services.makeRetryRunner()
        self.runner = runner
        if let result = await runner.run() {
            onCompleted(result)
        }
    }
}

extension View {
    /// Attach at the app root. See ``PendingLogPostRetry``.
    func pendingLogPostRetry(
        services: LogServices,
        onCompleted: @escaping (LogPostRetryResult) -> Void = { _ in }
    ) -> some View {
        modifier(PendingLogPostRetry(services: services, onCompleted: onCompleted))
    }
}

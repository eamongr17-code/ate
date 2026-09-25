import Foundation

/// **Callbacks for frameworks that answer on their own queue.**
///
/// A closure written inside a `@MainActor` type inherits main-actor isolation, and Swift 6 checks that
/// at runtime: when Speech or AVFAudio calls it from a background queue, the process dies in
/// `swift_task_reportUnexpectedExecutor`. The permission handlers were exactly that, the first time
/// anybody tapped the mic on a phone.
///
/// Built here — a `nonisolated` context — the closure is `@Sendable` and isolated to nothing, so it may
/// be called from any thread, and the compiler refuses any touch of main-actor state inside it.
public enum OffMainCallback {
    /// Resumes a continuation from whatever thread the framework calls back on.
    public nonisolated static func resuming<Value: Sendable>(
        _ continuation: CheckedContinuation<Value, Never>
    ) -> @Sendable (Value) -> Void {
        { continuation.resume(returning: $0) }
    }
}

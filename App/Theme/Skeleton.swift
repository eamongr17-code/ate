import SwiftUI

/// **One loading system** (design-language §5).
///
/// A skeleton is the app's REAL components, redacted, with shape-plausible placeholder content — so
/// when the page lands nothing reflows and the eye stays where it was. There are no bespoke grey
/// rectangles anywhere in this codebase, because a hand-drawn skeleton is a second layout that drifts
/// from the first.
///
/// Three rules, all of them about *time*:
/// - **150ms delay.** A page that arrives in 80ms must never flash a skeleton. Most do.
/// - **350ms minimum.** Once shown, it stays long enough to be read as loading rather than as a
///   flicker. Together these are what make a fast connection feel instant and a slow one feel calm.
/// - **0.2s crossfade on arrival**, never a slide and never a stagger. The rows are already at their
///   real heights; there is nothing to animate into place.
///
/// The redaction *breathes* — opacity 0.6↔1.0 over 1.2s — rather than shimmering. A shimmer is a
/// moving highlight, which is motion for its own sake on a screen whose whole message is "wait".
/// Reduce Motion gets a static 0.8 instead.
extension View {
    /// Shows `skeleton` in place of `self` while `isLoading`, with the delay, minimum and crossfade
    /// above, and applies the redaction treatment (redacted, no hit testing, one accessibility
    /// label) to it.
    ///
    /// - Parameter label: what VoiceOver says instead of reading eight fake dish names.
    func skeleton<Skeleton: View>(
        isLoading: Bool,
        label: String,
        @ViewBuilder skeleton: @escaping () -> Skeleton
    ) -> some View {
        SkeletonGate(isLoading: isLoading, label: label, content: { self }, skeleton: skeleton)
    }
}

/// The swap itself. Written as a view rather than a `ViewModifier` because it has to be able to
/// render something *other than* its content, which a modifier can't.
private struct SkeletonGate<Content: View, Skeleton: View>: View {
    let isLoading: Bool
    let label: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let skeleton: () -> Skeleton

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the skeleton is on screen right now — which is NOT `isLoading`: it lags it by the
    /// delay at the front and by the minimum at the back.
    @State private var isShowing = false
    @State private var shownAt: Date?
    /// Drives the breathe. A plain `Bool` toggled once, with a repeating autoreversing animation.
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            if isShowing {
                skeleton()
                    .redacted(reason: .placeholder)
                    .opacity(breatheOpacity)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .transition(.opacity)
            } else {
                content()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowing)
        .task(id: isLoading) { await settle() }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }

    /// 0.6↔1.0 over 1.2s means a 0.6s half-cycle, autoreversed.
    private var breatheOpacity: Double {
        if reduceMotion { return 0.8 }
        return isBreathing ? 1.0 : 0.6
    }

    private func settle() async {
        if isLoading {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isShowing = true
            shownAt = .now
        } else if isShowing {
            let elapsed = shownAt.map { Date.now.timeIntervalSince($0) } ?? 0
            let remaining = 0.350 - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }
            isShowing = false
            shownAt = nil
        }
    }
}

import SwiftUI

/// **The 44pt minimum hit target, for a control drawn smaller than it** (`docs/DESIGN.md`: "44pt
/// minimum hit targets").
///
/// The design draws plenty of controls under 44 — a 40 key, a 36 segment, a 28 byline — and their
/// faces are what Eamon approved, so the face cannot grow. What grows is the invisible part: the
/// face is padded out transparently inside its button (so the button's frame, which is both what a
/// finger hits and what VoiceOver outlines, is at least 44), and the button hands the same padding
/// back to its layout (so nothing around it moves by a point).
///
/// Two halves, because a `Button`'s frame is its label's: ``ateHitArea(_:)`` goes on the label,
/// after its face is drawn, and ``ateHitFootprint(_:)`` goes on the button.
struct AteHitOutset: Equatable, Sendable {
    var horizontal: CGFloat = 0
    var vertical: CGFloat = 0

    /// The outset that takes a face `width × height` to the minimum. Either side left out is taken as
    /// already wide (or tall) enough.
    init(width: CGFloat = AteMetrics.hit, height: CGFloat = AteMetrics.hit) {
        horizontal = max(0, (AteMetrics.hit - width) / 2)
        vertical = max(0, (AteMetrics.hit - height) / 2)
    }

    /// A 40-tall key pill — the composer's Score and Place, Search's scopes.
    static let key = AteHitOutset(height: AteMetrics.keyHeight)
    /// …and the icon-only 40 disc (the Diet key).
    static let keyDisc = AteHitOutset(width: AteMetrics.keyHeight, height: AteMetrics.keyHeight)
}

extension View {
    /// **A pill's drawn height, as a floor.** At the design's type size the pill is exactly
    /// `height`; at the accessibility sizes its lettering outgrows that, and the pill grows around
    /// it (with a hair of air) instead of clipping it.
    func atePillHeight(_ height: CGFloat) -> some View {
        padding(.vertical, AteMetrics.tight)
            .frame(minHeight: height)
    }

    /// On a control's LABEL, after its face (and the face's background) is drawn: pads it out
    /// transparently, and makes the padding hittable.
    func ateHitArea(_ outset: AteHitOutset) -> some View {
        padding(.horizontal, outset.horizontal)
            .padding(.vertical, outset.vertical)
            .contentShape(.rect)
    }

    /// On the control itself: gives the padding back, so the layout is the face's alone.
    func ateHitFootprint(_ outset: AteHitOutset) -> some View {
        padding(.horizontal, -outset.horizontal)
            .padding(.vertical, -outset.vertical)
    }
}

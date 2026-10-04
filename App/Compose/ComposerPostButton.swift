import AteKit
import PhotosUI
import SwiftUI

/// **Post** — the ink pill both composer screens carry in the same corner. One component, so the key
/// that saves the entry looks and behaves the same whether you were typing or talking.
///
/// Round 5: "Post" for a new entry, and "Posting…" while the sorter works behind it — the pill holds
/// the word, full strength, until the Summary takes the screen (``PostHold``). An edit keeps "Done":
/// the entry is already posted.
struct ComposerPostButton: View {
    /// "Post", "Posting…" while it holds, "Done" on an edit, or "Try again" after a save that did not land.
    var title = "Post"
    var isEnabled: Bool
    var isBusy = false
    /// Round 6: while it posts, the label prints its dots (``PostingDotsLabel``).
    var printsDots = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .ateText(.control)
                .padding(.horizontal, 18)
                .atePillHeight(Self.height)
                .background(AtePalette.surface.solid, in: .capsule)
                .foregroundStyle(AtePalette.surface.inverted)
                .ateHitArea(Self.hitOutset)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(Self.hitOutset)
        // Busy is not off: "Posting…" holds at full strength, it just takes no second tap.
        .disabled(isEnabled == false)
        .allowsHitTesting(isBusy == false)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.trailing, AteMetrics.regular)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var label: some View {
        if printsDots {
            PostingDotsLabel()
        } else {
            Text(title)
        }
    }

    /// The pill is drawn 38 tall; a finger gets 44.
    private static let height: CGFloat = 38
    private static let hitOutset = AteHitOutset(height: height)
}

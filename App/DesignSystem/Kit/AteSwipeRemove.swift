import SwiftUI

/// **A row's swipe-to-remove**: the trash glyph on the destructive red, never the word (Eamon,
/// 28 Oct). The word stays as the button's label, so VoiceOver still says what it does. One button
/// for every list a row can be swiped out of, so the swipe looks the same everywhere.
struct AteSwipeRemove: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label {
                Text(title)
            } icon: {
                AteIcon.trash.barImage(size: AteSwipeRemoveMetrics.glyph)
            }
            .labelStyle(.iconOnly)
        }
        .tint(AteColor.destructive)
    }
}

enum AteSwipeRemoveMetrics {
    /// The glyph on the swipe's red: a bar glyph's size.
    static let glyph: CGFloat = 22
}

import SwiftUI

/// **"Copy @eamon's review"** (`copy-their-review.html`, option A) — under the dishes on a tag's
/// scoring sheet: the tagger's avatar, then the action, in a 44pt pill in the field colour. One tap
/// takes their scores and words as the person's own, all still editable.
struct AteCopyReviewPill: View {
    let userID: UUID
    let handle: String
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.snug) {
                AteAvatar(userID: userID, handle: handle, size: .byline)
                Text(verbatim: "Copy @\(handle)'s review")
                    .ateText(.kitInkPill)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
            }
            .padding(.leading, AteMetrics.snug)
            .padding(.trailing, AteMetrics.loose)
            .atePillHeight(AteMetrics.hit)
            .background(palette.field, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("respond.copy")
    }
}

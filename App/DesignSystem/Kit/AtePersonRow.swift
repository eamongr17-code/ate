import SwiftUI

/// **A person row** — Search's People: the review-size avatar, the handle, their name under it. No
/// score (a score is only ever somebody's, about a dish) and no follower count. The place row's 62.
struct AtePersonRow: View {
    let userID: UUID
    let handle: String
    var name: String?
    var isFirst = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteDishRowMetrics.gap) {
                AteAvatar(userID: userID, handle: handle, size: .review)
                VStack(alignment: .leading, spacing: AteDishRowMetrics.lineGap) {
                    Text(verbatim: "@\(handle)")
                        .ateText(.rowTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                    if let name, name.isEmpty == false {
                        Text(name)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: AtePlaceRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.person")
    }
}

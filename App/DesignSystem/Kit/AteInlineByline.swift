import AteKit
import SwiftUI

/// **Somebody's name in the bar** — an entry's author: their avatar and handle, the age of the entry
/// as the muted subtitle under it. Leading, beside the system's back, exactly where every other
/// inline title sits (``AteInlineTitle``).
struct AteInlineByline: View {
    let userID: UUID
    let handle: String
    var subtitle: String?
    var avatarURL: URL?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteInlineBylineMetrics.gap) {
            AteAvatar(userID: userID, handle: handle, size: .byline, url: avatarURL)
            VStack(alignment: .leading, spacing: AteRootHeaderMetrics.inlineGap) {
                Text(verbatim: "@\(handle)")
                    .ateText(.kitInlineTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                if let subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .ateText(.kitInlineSubtitle)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum AteInlineBylineMetrics {
    static let gap: CGFloat = 7
}

import AteKit
import SwiftUI

/// **Somebody's name in the bar** — a pushed profile's inline title: their avatar and handle, the
/// city as the muted subtitle under it. Leading, beside the system's back, exactly where every other
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

extension View {
    /// A pushed profile's bar: the byline as the leading inline title (nothing until the name is
    /// known), the system's own title removed, as ``ateInlineTitle(_:subtitle:)`` does for a name.
    func ateInlineByline(_ byline: AteInlineByline?, fallback: String) -> some View {
        navigationTitle(byline.map { "@\($0.handle)" } ?? fallback)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if let byline {
                    ToolbarItem(placement: .topBarLeading) { byline }
                        .sharedBackgroundVisibility(.hidden)
                }
            }
            .ateHeaderGround()
    }
}

enum AteInlineBylineMetrics {
    static let gap: CGFloat = 7
}

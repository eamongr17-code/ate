import AteKit
import SwiftUI

/// **The post a dish came from** — the share card's `.linkcard` (`share-to-ate.html`): the post's
/// thumbnail with a play mark, then where it came from ("@sydneyeats on TikTok") over the caption in
/// quotes or the link. On the ground's linen, inset 10, rounded 18.
///
/// No thumbnail (Instagram shares none until its lookup exists, and a page may have no picture): the
/// slot is the field colour with the source's own glyph in it — never an empty grey square, never a
/// made-up picture.
struct AteLinkCard: View {
    let title: String
    var detail: String?
    var thumbnail: URL?
    /// The source's glyph, drawn in the slot when there is no picture.
    let mark: AteIcon

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteLinkCardMetrics.gap) {
            thumb
            VStack(alignment: .leading, spacing: AteLinkCardMetrics.lineGap) {
                Text(title)
                    .ateText(.kitLinkTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .ateText(.meta)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AteLinkCardMetrics.inset)
        .background(
            AteColor.ground,
            in: RoundedRectangle(cornerRadius: AteLinkCardMetrics.corner, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var thumb: some View {
        Color.clear
            .frame(width: AteLinkCardMetrics.thumbWidth, height: AteLinkCardMetrics.thumbHeight)
            .overlay {
                if let thumbnail {
                    AsyncImage(url: thumbnail) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            palette.field
                        }
                    }
                    .overlay {
                        AteIcon.play.view(size: AteLinkCardMetrics.play)
                            .foregroundStyle(AteKitColor.overPhoto)
                    }
                } else {
                    palette.field
                        .overlay {
                            mark.view(size: AteLinkCardMetrics.play)
                                .foregroundStyle(palette.muted)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AteLinkCardMetrics.thumbCorner, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum AteLinkCardMetrics {
    /// `.linkcard{gap:12px;padding:10px;border-radius:18px}`.
    static let gap: CGFloat = 12
    static let inset: CGFloat = 10
    static let corner: CGFloat = 18
    /// `.linkcard .th{width:64px;height:84px;border-radius:12px}`.
    static let thumbWidth: CGFloat = 64
    static let thumbHeight: CGFloat = 84
    static let thumbCorner: CGFloat = 12
    /// The play mark: `data-s="20"`.
    static let play: CGFloat = 20
    /// The two lines: `gap:3px`.
    static let lineGap: CGFloat = 3
}

extension OwnSaveSource {
    /// The mark on the thumbnail: TikTok's and Instagram's own; Lucide's pencil and link for the rest.
    var mark: AteIcon {
        switch self {
        case .manual: .edit
        case .tiktok: .tiktok
        case .instagram: .instagram
        case .link: .link
        }
    }
}

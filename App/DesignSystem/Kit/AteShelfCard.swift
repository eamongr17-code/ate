import AteKit
import SwiftUI

/// **The shelf card** — one card anatomy for every shelf and carousel in the app: a 168 × 210 photo
/// or letter tile at radius 16, the score token top left and the glass bookmark disc top right,
/// equally inset (10), and only text beneath it, flush with the image's edge — the dish, then the
/// place. Straight, never tilted.
struct AteShelfCard: View {
    let photo: AtePhoto
    let name: String
    var place: String?
    var score: AteScore?
    var isSaved = false
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteShelfCardMetrics.gap) {
            Button { onOpen?() } label: {
                AteThumb(photo: photo, size: .card)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                AteScoreToken(score)
                    .padding(AteShelfCardMetrics.inset)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if let onSave {
                    AteSaveButton(dishName: name, isSaved: isSaved, identifier: "card.save",
                                  style: .glass(.card), action: onSave)
                        .padding(AteShelfCardMetrics.inset)
                }
            }
            Button { onOpen?() } label: {
                VStack(alignment: .leading, spacing: AteShelfCardMetrics.lineGap) {
                    Text(name)
                        .ateText(.kitShelfDish)
                        .foregroundStyle(palette.fg)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let place {
                        Text(place)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("card.open")
        }
        .frame(width: AteShelfCardMetrics.width, alignment: .leading)
    }
}

enum AteShelfCardMetrics {
    static let width: CGFloat = 168
    /// `.card{gap:10px}`; `.card .t{gap:3px}`; the token and the disc `left/right:10px; top:10px`.
    static let gap: CGFloat = 10
    static let lineGap: CGFloat = 3
    static let inset: CGFloat = 10
    /// Between cards on a shelf: `gap:12px`.
    static let spacing: CGFloat = 12
}

/// **A shelf** — shelf cards in a row that runs off the trailing edge, from the screen gutter.
struct AteShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: AteShelfCardMetrics.spacing) {
                ForEach(items) { card($0) }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, AteMetrics.gutter, for: .scrollContent)
    }
}

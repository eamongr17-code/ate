import AteKit
import SwiftUI

/// **A ranked row** — The Top Ate's 2 to 8, under the hero: the rank as a big numeral, the dish's
/// thumbnail, the dish over its place, the score token and the bookmark. A field-coloured rule under
/// every row but the last.
struct AteRankedRow: View {
    let rank: Int
    let photo: AtePhoto
    let name: String
    var place: String?
    var score: AteScore?
    var isSaved = false
    var isLast = false
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteRankedRowMetrics.gap) {
            Button { onOpen?() } label: {
                HStack(spacing: AteRankedRowMetrics.gap) {
                    Text(verbatim: "\(rank)")
                        .ateText(.kitRankNumeral)
                        .foregroundStyle(palette.fg)
                        .frame(width: AteRankedRowMetrics.rankWidth)
                    AteThumb(photo: photo, size: .row)
                    VStack(alignment: .leading, spacing: AteRankedRowMetrics.lineGap) {
                        Text(name)
                            .ateText(.kitRankedDish)
                            .foregroundStyle(palette.fg)
                            .lineLimit(2)
                        if let place {
                            Text(place)
                                .ateText(.meta)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    AteScoreToken(score)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if let onSave {
                // `.rk .bm{margin:0 -12px 0 -6px}`.
                AteSaveButton(dishName: name, isSaved: isSaved, identifier: "ranked.save", action: onSave)
                    .padding(.leading, -AteRankedRowMetrics.saveLeading)
                    .padding(.trailing, -AteRankedRowMetrics.saveTrailing)
            }
        }
        .padding(.vertical, AteRankedRowMetrics.padding)
        .overlay(alignment: .bottom) {
            if isLast == false {
                Rectangle().fill(palette.field).frame(height: 1)
            }
        }
    }
}

enum AteRankedRowMetrics {
    /// `.rk{gap:12px; padding:9px 0}`, `.rk .n{width:28px}`, `.rk .d{gap:2px}`.
    static let gap: CGFloat = 12
    static let padding: CGFloat = 9
    static let rankWidth: CGFloat = 28
    static let lineGap: CGFloat = 2
    static let saveLeading: CGFloat = 6
    static let saveTrailing: CGFloat = 12
}

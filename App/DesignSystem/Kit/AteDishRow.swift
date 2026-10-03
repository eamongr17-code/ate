import AteKit
import SwiftUI

/// **A dish row** — the dish-first row every list prints (`.srow`): the straight thumbnail or letter
/// tile, the dish with its diet chips, the place (or a count) under it, the score token at the right
/// — an empty slot when nobody scored it — and the bookmark where the dish can be saved. Ruled at
/// the top by a hairline except the first.
///
/// The place menu's variant (`.mrow`) leads with the rank in mono fine print, takes the menu's 48
/// thumbnail and is ruled by the receipt's dashed line, because it sits on paper.
struct AteDishRow: View {
    enum Style: Equatable {
        /// Search, Saved, Ratings, a dish's "More like this": 76 high, 56 thumbnail, hairlines.
        case list
        /// A place's "What to order": 66 high, the rank, 48 thumbnail, dashed rules.
        case menu(rank: Int)
    }

    let photo: AtePhoto
    let name: String
    var tags: [DietTag] = []
    /// The place, or on a menu the count of people who ate it.
    var subtitle: String?
    /// An icon before the subtitle — the menu's people mark.
    var subtitleIcon: AteIcon?
    var score: AteScore?
    var style: Style = .list
    var isFirst = false
    var isSaved = false
    /// Present where the dish can be saved.
    var onSave: (() -> Void)?
    var onOpen: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteDishRowMetrics.gap) {
            Button { onOpen?() } label: {
                HStack(spacing: AteDishRowMetrics.gap) {
                    if case .menu(let rank) = style {
                        Text(String(format: "%02d", rank))
                            .ateText(.receiptLabel)
                            .foregroundStyle(palette.muted)
                            .frame(width: AteDishRowMetrics.rankWidth, alignment: .leading)
                    }
                    AteThumb(photo: photo, size: isMenu ? .menu : .row)
                    let lineGap = isMenu ? AteDishRowMetrics.menuLineGap : AteDishRowMetrics.lineGap
                    VStack(alignment: .leading, spacing: lineGap) {
                        HStack(spacing: TokenPillMetrics.dietGapOnName) {
                            Text(name)
                                .ateText(.rowTitle)
                                .foregroundStyle(palette.fg)
                                .lineLimit(2)
                            AteDietChips(tags: tags, onGround: isMenu == false)
                        }
                        if let subtitle {
                            HStack(spacing: AteMetrics.tight) {
                                subtitleIcon?.view(size: AteDishRowMetrics.subtitleIcon)
                                Text(subtitle).ateText(.meta).lineLimit(1)
                            }
                            .foregroundStyle(palette.muted)
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
                AteSaveButton(dishName: name, isSaved: isSaved, identifier: "row.save", action: onSave)
                    .padding(.vertical, -AteDishRowMetrics.saveBleed)
                    .padding(.trailing, -AteDishRowMetrics.saveBleed)
            }
        }
        .frame(minHeight: isMenu ? AteDishRowMetrics.menuHeight : AteDishRowMetrics.height)
        .overlay(alignment: .top) {
            if isFirst == false {
                if isMenu {
                    AteDashedLine(opacity: AteDishRowMetrics.menuRuleOpacity)
                } else {
                    AteHairline()
                }
            }
        }
    }

    private var isMenu: Bool {
        if case .menu = style { return true }
        return false
    }
}

enum AteDishRowMetrics {
    /// `.srow{gap:12px; min-height:76px}`, `.mrow{min-height:66px}`.
    static let gap: CGFloat = 12
    static let height: CGFloat = 76
    static let menuHeight: CGFloat = 66
    /// The name over its place: `gap:3px` (the menu's `2px`).
    static let lineGap: CGFloat = 3
    static let menuLineGap: CGFloat = 2
    /// The menu's rank column: `width:18px`.
    static let rankWidth: CGFloat = 18
    static let subtitleIcon: CGFloat = 13
    /// `border-top:1.5px dashed rgba(36,20,31,.25)`.
    static let menuRuleOpacity: Double = 0.25
    /// The bookmark's 44 target sits on the row's edge: the mark lines up with the column.
    static let saveBleed: CGFloat = 12
}

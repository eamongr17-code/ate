import AteKit
import SwiftUI

/// **A dish row** — the dish-first row every list prints (`.srow`): the straight thumbnail or letter
/// tile, the dish with its diet chips, the place under it, the score token at the right
/// — an empty slot when nobody scored it — and the bookmark where the dish can be saved. Ruled at
/// the top by a hairline except the first.
///
/// The place menu's variant (`.mrow`) leads with the rank as The Top Ate's numeral, takes the menu's 48
/// thumbnail and is ruled by the receipt's dashed line, because it sits on paper.
struct AteDishRow: View {
    enum Style: Equatable {
        /// Search, Saved, Ratings, a dish's "More like this": 76 high, 56 thumbnail, hairlines.
        case list
        /// A place's Top Ate: 66 high, the rank, 48 thumbnail, dashed rules.
        case menu(rank: Int)
    }

    let photo: AtePhoto
    let name: String
    var tags: [DietTag] = []
    /// The place, or what the list knows under the dish.
    var subtitle: String?
    var score: AteScore?
    /// A dish you saved yourself: where it came from, as a small ink disc on the thumbnail's corner
    /// (`beta-saved` mockup). Such a dish never has a score.
    var mark: AteIcon?
    var style: Style = .list
    var isFirst = false
    var isSaved = false
    /// Present where the dish can be saved.
    var onSave: (() -> Void)?
    var onOpen: (() -> Void)?
    /// A menu row's cover photo opens the shell's viewer (a letter tile is part of the row and opens
    /// the dish); this hears that it did.
    var onPhoto: (() -> Void)?
    /// Under the dish on the full-screen cover: where it was eaten.
    var photoByline: String?
    /// A place's Top Ate: the diet pills open how many people of each diet logged the dishes wearing
    /// them (`diet-more.html`). `nil`, the pills are only pills.
    var tagCounts: (() -> [AteDietCountsList.Row])?
    /// The pills were tapped.
    var onTagCounts: (() -> Void)?

    @State private var isShowingTagCounts = false
    /// Where a menu row's thumbnail sits, for its photo to fly out of and back into.
    @State private var thumbFrames = AtePhotoTileFrames()
    @Environment(\.atePalette) private var palette
    @Environment(\.atePhotoViewer) private var showPhotos
    @Environment(\.atePhotoOriginRelay) private var originRelay
    @Environment(\.atePhotoHiddenSource) private var hiddenSource

    var body: some View {
        HStack(spacing: AteDishRowMetrics.gap) {
            Button { onOpen?() } label: {
                HStack(spacing: AteDishRowMetrics.gap) {
                    if case .menu(let rank) = style {
                        Text(verbatim: "\(rank)")
                            .ateText(.kitRankNumeral)
                            .foregroundStyle(palette.fg)
                            .frame(width: AteDishRowMetrics.rankWidth)
                    }
                    AteThumb(photo: photo, size: isMenu ? .menu : .row)
                        .atePhotoSource(thumbFrames, index: 0, radius: AteThumbMetrics(.menu).radius)
                        // While the viewer has its photo: the photo is in flight over it.
                        .opacity(isMenu && hiddenSource == thumbFrames.sourceID(0) ? 0 : 1)
                        .overlay(alignment: .bottomTrailing) {
                            if let mark { AteSourceMark(icon: mark) }
                        }
                    let lineGap = isMenu ? AteDishRowMetrics.menuLineGap : AteDishRowMetrics.lineGap
                    VStack(alignment: .leading, spacing: lineGap) {
                        HStack(spacing: TokenPillMetrics.dietGapOnName) {
                            Text(name)
                                .ateText(.rowTitle)
                                .foregroundStyle(palette.fg)
                                .lineLimit(2)
                            chips
                        }
                        if let subtitle {
                            Text(subtitle)
                                .ateText(.meta)
                                .lineLimit(1)
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
            .accessibilityActions {
                if tagCounts != nil, tags.isEmpty == false {
                    Button("Diet counts") { showTagCounts() }
                }
            }
            if let onSave {
                AteSaveButton(dishName: name, isSaved: isSaved, identifier: "row.save", action: onSave)
                    .padding(.vertical, -AteDishRowMetrics.saveBleed)
                    .padding(.trailing, -AteDishRowMetrics.saveBleed)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isMenu ? AteDishRowMetrics.menuHeight : AteDishRowMetrics.height)
        .overlay(alignment: .leading) {
            if isMenu, photo.image != nil || photo.url != nil {
                // Over the thumbnail, beside the row's own button: a button in a button's label is
                // never heard.
                Button {
                    onPhoto?()
                    let thumb = AteThumbMetrics(.menu)
                    originRelay?.note(thumbFrames.origin(
                        side: thumb.height, radius: { _ in thumb.radius }, angle: { _ in 0 }, ring: nil,
                        focus: { _ in photo.focus }, layer: { _ in 0 }
                    ))
                    let dishes = AtePhotoDishes.one(name, photos: [photo], byline: photoByline)
                    showPhotos([photo], at: 0, dishes: dishes)
                } label: {
                    Color.clear
                        .frame(width: AteThumbMetrics(.menu).height, height: AteThumbMetrics(.menu).height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, AteDishRowMetrics.rankWidth + AteDishRowMetrics.gap)
                .accessibilityLabel("Photo of \(name)")
                .accessibilityIdentifier("place.dish.photo")
            }
        }
        .overlay(alignment: .top) {
            if isFirst == false {
                if isMenu {
                    AteDashedRule()
                } else {
                    AteHairline()
                }
            }
        }
    }

    /// The dish's pills; where they open counts, a tap on them is theirs, not the row's.
    @ViewBuilder
    private var chips: some View {
        let pills = AteDietChips(tags: tags, onGround: isMenu == false)
        if let tagCounts, tags.isEmpty == false {
            pills
                .padding(.vertical, AteDishRowMetrics.pillBleed)
                .contentShape(.rect)
                .padding(.vertical, -AteDishRowMetrics.pillBleed)
                .highPriorityGesture(TapGesture().onEnded { showTagCounts() })
                .ateDietCountsPopover(isPresented: $isShowingTagCounts) {
                    AteDietCountsList(rows: tagCounts())
                }
        } else {
            pills
        }
    }

    private func showTagCounts() {
        onTagCounts?()
        isShowingTagCounts = true
    }

    private var isMenu: Bool {
        if case .menu = style { return true }
        return false
    }
}

/// **Where an own save came from** — the glyph on an ink disc, or an app's own mark on that app's disc
/// (TikTok's black, Instagram's gradient), ringed in the ground so it lifts off the thumbnail.
struct AteSourceMark: View {
    let icon: AteIcon

    @Environment(\.atePalette) private var palette

    var body: some View {
        icon.view(size: AteSourceMarkMetrics.glyph)
            .foregroundStyle(icon.brand == nil ? palette.inverted : AteColor.onBrand)
            .frame(width: AteSourceMarkMetrics.face, height: AteSourceMarkMetrics.face)
            .background(icon.brand?.fill(size: AteSourceMarkMetrics.face) ?? AnyShapeStyle(palette.solid), in: .circle)
            // The ring is the ground disc behind, not a stroke over the fill: a stroke leaves the fill's
            // anti-aliased edge showing round its outside as a hairline.
            .padding(AteSourceMarkMetrics.ring)
            .background(palette.ground, in: .circle)
            .offset(x: AteSourceMarkMetrics.overhang, y: AteSourceMarkMetrics.overhang)
            .accessibilityHidden(true)
    }
}

enum AteSourceMarkMetrics {
    /// `.src{width:22px;height:22px;right:-5px;bottom:-5px;box-shadow:0 0 0 2.5px ground}`.
    static let disc: CGFloat = 22
    static let glyph: CGFloat = 12
    static let ring: CGFloat = 2.5
    /// The coloured face inside the ring.
    static let face: CGFloat = disc - 2 * ring
    static let overhang: CGFloat = 5
}

enum AteDishRowMetrics {
    /// `.srow{gap:12px; min-height:76px}`, `.mrow{min-height:66px}`.
    static let gap: CGFloat = 12
    static let height: CGFloat = 76
    static let menuHeight: CGFloat = 66
    /// A row's diet pills are 20 high; a tap on them gets 12 more each way before it is the row's.
    static let pillBleed: CGFloat = 12
    /// The name over its place: `gap:3px` (the menu's `2px`).
    static let lineGap: CGFloat = 3
    static let menuLineGap: CGFloat = 2
    /// The menu's rank column: The Top Ate's `.rk .n{width:28px}`.
    static let rankWidth: CGFloat = AteRankedRowMetrics.rankWidth
    /// The bookmark's 44 target sits on the row's edge: the mark lines up with the column.
    static let saveBleed: CGFloat = 12
}

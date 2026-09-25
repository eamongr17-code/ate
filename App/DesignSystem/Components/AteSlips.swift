import AteKit
import SwiftUI

/// **The slip.** One component, three surfaces.
///
/// A torn piece of paper carrying, in order: the byline (feed only), the dish rows, the words (whole
/// in the journal, two lines elsewhere), a small tilted photo cluster, and the foot line. Tapping it
/// opens the entry; tapping a score pill in the words opens that score's dish.
///
/// `onSave` is what makes it a feed or profile slip: pass it and every dish row grows a bookmark,
/// because a save is always one dish and never a whole entry (PRODUCT.md decision 7). Pass a
/// `byline` and the person is named above the stack. Your own journal has neither.
struct EntrySlip: View {
    let slip: AteSlip
    var onOpen: (() -> Void)?
    var onProfile: (() -> Void)?
    /// Nil on the journal: your own entries are not saved, they are written.
    var onSave: ((AteSlip.Dish) -> Void)?
    /// The foot line's place opens the place page. Wired on every surface a slip appears on — the
    /// same tap must do the same thing in the journal, the feed and on a profile (AGENTS.md rule 2).
    var onPlace: ((UUID) -> Void)?
    /// …and a dish's name opens its page. The score and the bookmark beside it are not part of the
    /// target: one is a fact, the other is an action.
    var onDish: ((AteSlip.Dish) -> Void)?
    /// The identifier a drive reaches for. The journal's slips have always been `journal.slip`.
    var identifier = "journal.slip"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if isInteractive {
                // A slip with its own buttons in it cannot itself be a button — a tap inside a
                // `Button`'s label belongs to the outer button. So the parts that open the entry
                // say so one by one.
                paper { content(interactive: true) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
            } else {
                Button {
                    onOpen?()
                } label: {
                    paper { content(interactive: false) }
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
            }
        }
    }

    /// Whether the slip has controls of its own. When it does it cannot itself be a button — a tap
    /// inside a `Button`'s label belongs to the outer button — so its bands say what they open one
    /// by one instead.
    private var isInteractive: Bool {
        onSave != nil || onProfile != nil || onPlace != nil || onDish != nil
    }

    private func paper(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            // `padding:12px 16px 14px` under a byline; `4px 16px 14px` when the slip opens straight
            // on its first 44pt dish row, which carries its own air.
            .padding(.top, slip.byline == nil ? AteMetrics.slipPaddingTopBare : AteMetrics.slipPaddingTop)
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.bottom, AteMetrics.slipPaddingBottom + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateSlip()
            .background(AteColor.slip, in: ReceiptPaper())
    }

    @ViewBuilder
    private func content(interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
            if let byline = slip.byline {
                bylineRow(byline, interactive: interactive)
            }
            if slip.dishes.isEmpty == false {
                dishStack(interactive: interactive)
            }
            // The words and the photos are one target: they are the entry, in miniature.
            if hasBody {
                tappable(interactive: interactive, part: "body") {
                    VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
                        if slip.words.plain.isEmpty == false {
                            InlineTokenText(
                                composition: slip.words,
                                style: .slipProse,
                                lineLimit: slip.wordsLineLimit,
                                onScoreDish: onDish.map { open in { (dishID: UUID) in open(scoredDish(dishID)) } }
                            )
                        }
                        if slip.photos.isEmpty == false {
                            PhotoCluster(
                                photos: slip.photos,
                                side: AteMetrics.clusterPhoto,
                                topPadding: AteMetrics.hairspace,
                                bottomPadding: 0
                            )
                        }
                    }
                }
            }
            // The foot line is its own band: the place goes to the place, everything above it goes
            // to the entry. (A sibling rather than a child of the body's button — a tap inside a
            // button's label belongs to that button, so a nested one would never be heard.)
            if slip.place != nil || slip.meta != .none {
                footLine(interactive: interactive)
            }
        }
    }

    /// The dish a score pill in the words points at: the slip's own line for it, or a bare one with
    /// the id — the dish page needs nothing more, and the pill never exists without a sorted line.
    private func scoredDish(_ dishID: UUID) -> AteSlip.Dish {
        slip.dishes.first { $0.dishID == dishID } ?? AteSlip.Dish(id: dishID, dishID: dishID, name: "")
    }

    private var hasBody: Bool {
        slip.words.plain.isEmpty == false || slip.photos.isEmpty == false
    }

    /// Wraps a band in a button when the slip has its own controls, and leaves it alone when the
    /// whole slip is already one. `part` is what a drive reaches for: with bookmarks in the way, the
    /// slip is no longer one element, so its two halves are named.
    @ViewBuilder
    private func tappable(
        interactive: Bool,
        part: String,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        if interactive, let onOpen {
            Button(action: onOpen) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).\(part)")
        } else {
            content()
        }
    }

    // MARK: - The dish rows

    private func dishStack(interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slip.dishes.enumerated()), id: \.element.id) { index, dish in
                VStack(spacing: 0) {
                    // The design rules rows at the TOP, so the first dish starts on clean paper.
                    if index > 0 { AteHairline() }
                    dishRow(dish, interactive: interactive)
                }
            }
        }
    }

    /// **A dish row, as the two artboards draw it.**
    ///
    /// A name that fits on one line is centred against its score in a 44pt row (`Main.dc.html`:
    /// `align-items:center; min-height:44px`). A name that wraps sets its score and bookmark level
    /// with its FIRST line and clamps at two (`JournalLong.dc.html`: `align-items:baseline;
    /// padding:9px 0`, `.clamp2`). `ViewThatFits` picks between them, so both boards hold exactly.
    ///
    /// Either way the row is built the way the CSS builds it rather than on SwiftUI's own baselines:
    /// exact line boxes (21 a name line, 26 the score) placed where the markup places them, and the
    /// type inside lifted onto the CSS baseline (``AteFont/exactBaselineDrop(for:dynamicTypeSize:)``)
    /// — so a row is exactly the markup's 44, or 64.5 for a name on two lines.
    private func dishRow(_ dish: AteSlip.Dish, interactive: Bool) -> some View {
        let metrics = DishRowMetrics(dynamicTypeSize: dynamicTypeSize)
        return HStack(alignment: .top, spacing: Self.bookmarkGap) {
            dishTarget(dish, interactive: interactive) {
                ViewThatFits(in: .horizontal) {
                    // One line: the name centred on the 26pt score slot, filled or empty.
                    HStack(alignment: .center, spacing: AteMetrics.regular) {
                        dishName(dish, metrics: metrics)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        score(dish, lift: metrics.scoreLift)
                    }
                    .frame(minHeight: metrics.scoreBox)
                    // Wrapping: the first line's baseline shared with the score's.
                    HStack(alignment: .top, spacing: AteMetrics.regular) {
                        dishName(dish, metrics: metrics)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, dish.score == nil ? 0 : metrics.baselineStep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        score(dish, lift: metrics.scoreLift)
                    }
                }
            }
            if let onSave {
                bookmark(dish, action: onSave)
                    // No text of its own: it centres on the numeral's caps, which is the centre of
                    // the score slot whether or not the slot is filled.
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] - metrics.markCentre }
            }
        }
        // `padding:9px 0` on a 26pt slot is the 44 minimum exactly.
        .padding(.vertical, AteMetrics.slipDishPadding)
        .frame(minHeight: AteMetrics.hit, alignment: .top)
    }

    private func dishName(_ dish: AteSlip.Dish, metrics: DishRowMetrics) -> some View {
        Text(dish.name)
            .ateTextExact(.slipDish)
            .offset(y: -metrics.nameLift)
    }

    /// `gap:14px` between the score and its bookmark.
    private static let bookmarkGap: CGFloat = 14

    /// A dish row's geometry, from the fonts — the numbers the CSS arrives at by itself.
    private struct DishRowMetrics {
        /// The score's line box: the row's one fixed slot.
        let scoreBox: CGFloat
        /// How far a wrapping name's box starts below the score's, so their CSS baselines meet.
        let baselineStep: CGFloat
        let nameLift: CGFloat
        let scoreLift: CGFloat
        /// Where the bookmark's centre sits below the slot's top: the numeral's cap centre.
        let markCentre: CGFloat

        init(dynamicTypeSize: DynamicTypeSize) {
            let nameBaseline = AteFont.cssBaseline(for: .slipDish, dynamicTypeSize: dynamicTypeSize)
            let scoreBaseline = AteFont.cssBaseline(for: .slipScore, dynamicTypeSize: dynamicTypeSize)
            scoreBox = AteTextStyle.slipScore.lineBox(dynamicTypeSize)
            baselineStep = max(0, scoreBaseline - nameBaseline)
            nameLift = AteFont.exactBaselineDrop(for: .slipDish, dynamicTypeSize: dynamicTypeSize)
            scoreLift = AteFont.exactBaselineDrop(for: .slipScore, dynamicTypeSize: dynamicTypeSize)
            markCentre = scoreBaseline - AteFont.capHeight(for: .slipScore, dynamicTypeSize: dynamicTypeSize) / 2
        }
    }

    /// Where a dish row goes. **The dish, when there is a dish page to go to** — the name and its
    /// score are the item, and the item has a page. Without one it falls back to opening the entry,
    /// which is what a slip did before those pages existed.
    @ViewBuilder
    private func dishTarget(
        _ dish: AteSlip.Dish,
        interactive: Bool,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        if let onDish {
            Button { onDish(dish) } label: {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).dish")
        } else {
            tappable(interactive: interactive, part: "dish") { content() }
        }
    }

    /// A scored dish prints its score like a price. An unscored one prints **nothing** — the slot
    /// is simply empty: no star, no zero, no dash (design rule 7; `docs/DESIGN.md`).
    @ViewBuilder
    private func score(_ dish: AteSlip.Dish, lift: CGFloat) -> some View {
        if let score = dish.score {
            // The star centres on the 26pt box, which is where the lifted numeral's caps land.
            HStack(alignment: .center, spacing: 5) {
                AteIcon.starFilled.view(size: 16)
                Text(ScoreFormat.halfStep(score.value))
                    .ateTextExact(.slipScore)
                    .monospacedDigit()
                    .offset(y: -lift)
            }
            .fixedSize()
            .accessibilityElement()
            .accessibilityLabel("Scored \(ScoreFormat.halfStep(score.value)) out of 5")
        }
    }

    private func bookmark(_ dish: AteSlip.Dish, action: @escaping (AteSlip.Dish) -> Void) -> some View {
        Button {
            action(dish)
        } label: {
            (dish.isSaved ? AteIcon.saved : AteIcon.save)
                .view(size: 22)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // `margin:-10px -12px -10px 0` — the target stays 44, the mark sits on the paper's edge.
        .padding(.vertical, -10)
        .padding(.trailing, -12)
        .accessibilityLabel(dish.isSaved ? "Saved \(dish.name)" : "Save \(dish.name)")
        .accessibilityAddTraits(dish.isSaved ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("slip.save")
    }

    // MARK: - The foot line

    /// `.placeline` — pin (muted) + place (600) + suburb (muted), and the journal's date or a
    /// profile's age at the right. The place truncates first; the suburb and the date never wrap and
    /// never shrink.
    private func footLine(interactive: Bool) -> some View {
        HStack(spacing: 0) {
            if let place = slip.place {
                placeTarget(place, interactive: interactive)
                    .layoutPriority(0)
            }
            Spacer(minLength: 0)
            metaValue
                // `margin-left:auto; padding-left:7px`.
                .padding(.leading, Self.metaGap)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(minHeight: AteMetrics.slipFootHeight)
        // `margin:2px 0 -6px` — a hair more air above than the band gap, and tucked towards the tear.
        .padding(.top, AteMetrics.slipFootTop)
        .padding(.bottom, AteMetrics.slipFootBottom)
    }

    /// `gap:5px` between pin, name and suburb, and the suburb's own `margin-left:2px`.
    private static let footGap: CGFloat = 5
    private static let suburbGap: CGFloat = 7
    private static let metaGap: CGFloat = 7

    /// How far the place's target is grown past its glyphs, and given straight back to the layout.
    /// A 28pt line on a moving list is a miss, but growing the band would push every slip taller
    /// than the artboard draws it — so the air is padded on and the margin padded off, exactly as a
    /// slip's bookmark does it.
    private static let placeTargetPadding: CGFloat = 8

    @ViewBuilder
    private func placeTarget(_ place: String, interactive: Bool) -> some View {
        let name = HStack(spacing: 0) {
            AteIcon.place.view(size: 15)
                .foregroundStyle(AtePalette.slip.muted)
                .padding(.trailing, Self.footGap)
            Text(place)
                .ateText(.controlSmall)
                .foregroundStyle(AtePalette.slip.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            if let suburb = slip.suburb {
                Text(suburb)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.slip.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Self.suburbGap)
                    .layoutPriority(1)
            }
        }

        if interactive, let onPlace, let placeID = slip.placeID {
            Button {
                onPlace(placeID)
            } label: {
                name
                    .padding(.vertical, Self.placeTargetPadding)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -Self.placeTargetPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel([place, slip.suburb].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("\(identifier).place")
        } else {
            name.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var metaValue: some View {
        switch slip.meta {
        case .day(let text), .age(let text):
            Text(text)
                .ateText(.meta)
                .foregroundStyle(AtePalette.slip.muted)
                .lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    // MARK: - The byline

    private func bylineRow(_ byline: AteByline, interactive: Bool) -> some View {
        HStack(spacing: AteMetrics.regular) {
            Group {
                if interactive, let onProfile {
                    Button(action: onProfile) { bylineName(byline) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("@\(byline.handle)")
                        .accessibilityIdentifier("slip.byline")
                } else {
                    bylineName(byline)
                }
            }
            Spacer(minLength: 0)
            Text(byline.age)
                .ateText(.meta)
                .foregroundStyle(AtePalette.slip.muted)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private func bylineName(_ byline: AteByline) -> some View {
        HStack(spacing: AteMetrics.snug) {
            AteAvatar(userID: byline.userID, handle: byline.handle)
            // A long handle truncates (`.trunc`); the age beside it never does.
            Text(verbatim: "@\(byline.handle)")
                .ateText(.controlSmall)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(.rect)
    }
}

#if DEBUG
#Preview("Slips") {
    ScrollView {
        VStack(spacing: AteMetrics.slipGap) {
            EntrySlip(slip: .previewJournal, onOpen: {})
            EntrySlip(slip: .previewFeed, onOpen: {}, onProfile: {}, onSave: { _ in },
                      identifier: "feed.slip")
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif

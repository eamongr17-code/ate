import AteKit
import SwiftUI
import UIKit

/// **A dish row** — the dish-first unit every card leads with, and the entry page too
/// (`EntryHier.dc.html` builds its rows from the card's own markup).
///
/// Name (`.h` 20/21) left, score (`.h` 26 with a filled 16 star) right, 44 minimum; a name that wraps
/// sets its score level with its first line and clamps at two. Dietary tags follow the name as linen
/// chips (`DietTagsB`: 6 after the name, 4 apart, lifted 3). An unrated dish leaves the score slot
/// empty (design rule 7). On somebody else's entry every row carries its own bookmark — a save is
/// always one dish.
///
/// One component, so the journal, the feed, a profile, a place and the entry page cannot drift into
/// drawing the same dish differently.
struct SlipDishRow: View {
    let dish: AteSlip.Dish
    /// What a tap on the name and score does — the dish's page, or the entry. `nil` leaves the row
    /// inert, for a slip that is itself one button.
    var action: (() -> Void)?
    /// The other thing the row can do, one long press away — the entry page's correction.
    var secondary: (title: String, action: () -> Void)?
    /// Present where the dish can be saved: somebody else's entry, in any list or on its page.
    var onSave: (() -> Void)?
    var identifier = "journal.slip"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// **The row, as the two artboards draw it.**
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
    var body: some View {
        let metrics = DishRowMetrics(dynamicTypeSize: dynamicTypeSize)
        return HStack(alignment: .top, spacing: Self.bookmarkGap) {
            target {
                ViewThatFits(in: .horizontal) {
                    // One line: the name centred on the 26pt score slot, filled or empty.
                    HStack(alignment: .center, spacing: AteMetrics.regular) {
                        name(metrics: metrics)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        score(lift: metrics.scoreLift)
                    }
                    .frame(minHeight: metrics.scoreBox)
                    // Wrapping: the first line's baseline shared with the score's.
                    HStack(alignment: .top, spacing: AteMetrics.regular) {
                        name(metrics: metrics)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, dish.score == nil ? 0 : metrics.baselineStep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        score(lift: metrics.scoreLift)
                    }
                }
            }
            if let onSave {
                bookmark(action: onSave)
                    // No text of its own: it centres on the numeral's caps, which is the centre of
                    // the score slot whether or not the slot is filled.
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] - metrics.markCentre }
            }
        }
        // `padding:9px 0` on a 26pt slot is the 44 minimum exactly.
        .padding(.vertical, AteMetrics.slipDishPadding)
        .frame(minHeight: AteMetrics.hit, alignment: .top)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func target(@ViewBuilder _ content: () -> some View) -> some View {
        if let action {
            Button(action: action) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let secondary {
                    Button(secondary.title, action: secondary.action)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).dish")
        } else {
            content()
        }
    }

    /// The name, and its tags riding on its last line — one `Text`, so a chip wraps with the word
    /// it follows exactly as the markup's inline `<span class="diet">` does.
    private func name(metrics: DishRowMetrics) -> some View {
        var text = Text(dish.name)
        if dish.tags.isEmpty == false {
            text = Text("\(text)\(DietTagRun.text(tags: dish.tags, dynamicTypeSize: dynamicTypeSize))")
        }
        return text
            .ateTextExact(.slipDish)
            .textRenderer(DietTagRun.Renderer(dynamicTypeSize: dynamicTypeSize))
            .offset(y: -metrics.nameLift)
            .accessibilityLabel(([dish.name] + dish.tags.map(\.spokenName)).joined(separator: ", "))
    }

    /// A scored dish prints its score like a price. An unscored one prints **nothing** — the slot
    /// is simply empty: no star, no zero, no dash (design rule 7; `docs/DESIGN.md`).
    @ViewBuilder
    private func score(lift: CGFloat) -> some View {
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

    private func bookmark(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
}

/// **A dish's tags as text** riding inside the name's `Text`: 6 after the name, 4 apart, each
/// code in the chip's own voice, lifted 3 (`.dname .diet`). Real glyphs, so they scale with Dynamic
/// Type (to the chip style's cap) and wrap with the word they follow; ``Renderer`` paints each
/// chip's linen capsule behind its code. No picture is involved anywhere.
enum DietTagRun {
    /// Marks a chip's characters — its padding and its code — so the renderer can find them.
    struct Chip: TextAttribute {
        let index: Int
    }

    static func text(tags: [DietTag], dynamicTypeSize: DynamicTypeSize) -> Text {
        let font = AteFont.uiFont(for: .dietTag, dynamicTypeSize: dynamicTypeSize)
        let scale = scale(dynamicTypeSize)
        var run = Text(verbatim: "")
        for (index, tag) in tags.enumerated() {
            let gap = index == 0 ? TokenPillMetrics.dietGapOnName : TokenPillMetrics.dietGapBetween
            let pad = spacer(TokenPillMetrics.dietPadding * scale, font: font)
            let code = Text(verbatim: tag.label)
                .font(Font(font))
                .tracking(font.pointSize * AteTextStyle.dietTag.trackingEm)
                .foregroundStyle(AtePalette.automatic.muted)
            let chip = Text("\(pad)\(code)\(pad)")
                .baselineOffset(TokenPillMetrics.dietRiseOnName * scale)
                .customAttribute(Chip(index: index))
            run = Text("\(run)\(spacer(gap * scale, font: font))\(chip)")
        }
        return run
    }

    /// How far Dynamic Type has taken the chip from its drawn 10.5 (capped with the style).
    static func scale(_ dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        AteFont.uiFont(for: .dietTag, dynamicTypeSize: dynamicTypeSize).pointSize / AteTextStyle.dietTag.size
    }

    /// A space exactly `width` wide: an em space (U+2003, one em by definition) set at `width`
    /// points. Kerning a normal space was ignored at a run's edge.
    private static func spacer(_ width: CGFloat, font: UIFont) -> Text {
        Text(verbatim: "\u{2003}").font(Font(font.withSize(max(0.5, width))))
    }

    /// Paints each chip's capsule — 18 high (scaled), on the ground colour — under its code.
    struct Renderer: TextRenderer {
        let dynamicTypeSize: DynamicTypeSize

        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            let font = AteFont.uiFont(for: .dietTag, dynamicTypeSize: dynamicTypeSize)
            let scale = DietTagRun.scale(dynamicTypeSize)
            let height = TokenPillMetrics.dietHeight * scale
            // The chip's baseline sits `height/2 + (ascender + descender)/2` below its top.
            let baselineFromTop = height / 2 + (font.ascender + font.descender) / 2
            for line in layout {
                var chips: [Int: CGRect] = [:]
                var baselines: [Int: CGFloat] = [:]
                for run in line {
                    guard let chip = run[Chip.self] else { continue }
                    let bounds = run.typographicBounds
                    chips[chip.index] = chips[chip.index].map { $0.union(bounds.rect) } ?? bounds.rect
                    baselines[chip.index] = bounds.origin.y
                }
                for (index, rect) in chips {
                    let baseline = baselines[index] ?? rect.maxY
                    let capsule = CGRect(x: rect.minX, y: baseline - baselineFromTop, width: rect.width, height: height)
                    context.fill(Capsule().path(in: capsule), with: .color(AteColor.ground))
                }
                context.draw(line)
            }
        }
    }
}

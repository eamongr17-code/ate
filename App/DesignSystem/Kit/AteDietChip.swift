import AteKit
import SwiftUI

/// **A diet tag** — GF, DF, V, VG, NF: the code in capitals, in the score pill's DM Mono 500, muted,
/// on a pill of the score's height with the ground showing through (`.diet`), in tinted glass. The
/// existing ``DietTagChip``, with the one decision a caller makes named: whether it sits on paper (a
/// slip, a sheet) or on the ground itself, where a linen chip on linen would be no chip at all and it
/// recesses to the field tone instead.
struct AteDietChip: View {
    let tag: DietTag
    var onGround = false
    /// Where it sits in its dish's grouped chip (``DietChipJoin``); alone, a whole capsule.
    var join: DietChipJoin = []

    @Environment(\.atePalette) private var palette

    var body: some View {
        let fill = onGround ? palette.field : AteColor.tagFill
        if join.isEmpty {
            // A whole chip on its own is live: Liquid Glass tinted with its muted fill.
            DietTagChip(tag: tag, fill: nil).ateGlassPill(fill, in: .capsule)
        } else {
            DietTagChip(tag: tag, fill: fill, join: join)
        }
    }
}

/// A dish's tags after its name, grouped into one chip — `GF V VG` (Eamon, 7 Oct).
struct AteDietChips: View {
    let tags: [DietTag]
    var onGround = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        if tags.isEmpty == false {
            // One glass capsule for the whole group, so the codes read as one chip with no seams.
            HStack(spacing: 0) {
                ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                    DietTagChip(tag: tag, fill: nil, join: .at(index, of: tags.count))
                }
            }
            .ateGlassPill(onGround ? palette.field : AteColor.tagFill, in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}

/// **A diet code as a button** — where a code is chosen rather than shown: the filter sheet's Diet
/// group and the composer's Diet unfold, so the two match. Key size (40 high, a 44 target),
/// Bricolage 600 at 14; the field colour when off, ink with light lettering when on. The display
/// chip (``AteDietChip``) stays the small tag a dish wears.
struct AteDietPill: View {
    let tag: DietTag
    var isOn = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(tag.label)
                .ateText(.controlSmall)
                .lineLimit(1)
                .padding(.horizontal, AteDietPillMetrics.padding)
                .frame(minWidth: AteDietPillMetrics.height, minHeight: AteDietPillMetrics.height)
                .foregroundStyle(isOn ? palette.inverted : ComposerKeyColor.placeInk)
                .background(isOn ? palette.solid : ComposerKeyColor.place, in: .capsule)
                // The face is 40; a finger gets 44.
                .padding(.vertical, AteDietPillMetrics.hitOutset)
                .contentShape(.rect)
                .padding(.vertical, -AteDietPillMetrics.hitOutset)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(tag.spokenName)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "diet.\(tag.rawValue)")
    }
}

enum AteDietPillMetrics {
    /// A composer key's height and its lettered inset (`.k-code{padding:0 13px}`).
    static let height: CGFloat = AteMetrics.keyHeight
    static let padding: CGFloat = 13
    static let hitOutset: CGFloat = (AteMetrics.hit - AteMetrics.keyHeight) / 2
}

// MARK: - The counts behind the pills

/// **The "?" after a dish's diet pills** (`diet-more.html`): the pills say nothing about numbers, so
/// this opens them — a small popover listing each code, its name and how many people of that diet
/// logged the dish. A plain circled "?", 22 across, with a full finger's target.
struct AteDietCountsButton<Popover: View>: View {
    @Binding var isPresented: Bool
    var onOpen: (() -> Void)?
    @ViewBuilder var popover: Popover

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button {
            onOpen?()
            isPresented = true
        } label: {
            Text(verbatim: "?")
                .ateText(.controlSmall)
                .foregroundStyle(palette.muted)
                .frame(width: AteDietCountsMetrics.disc, height: AteDietCountsMetrics.disc)
                .overlay(Circle().strokeBorder(palette.muted, lineWidth: AteDietCountsMetrics.ring))
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
                .padding(-AteDietCountsMetrics.hitBleed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Diet counts")
        .accessibilityIdentifier("diet.counts")
        .ateDietCountsPopover(isPresented: $isPresented) { popover }
    }
}

/// **The popover itself** — one line per row: the code's pill (on the dish page), what it is, and
/// the person glyph with the count. Under a hairline, the one reminder: what people ate is not a
/// promise about allergens.
struct AteDietCountsList: View {
    struct Row: Identifiable, Hashable {
        let id: String
        /// The code's pill, where the rows are codes; a place's rows are dishes and carry none.
        var tag: DietTag?
        let title: String
        let people: String
    }

    let rows: [Row]

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteDietCountsMetrics.rowGap) {
            ForEach(rows) { row in
                HStack(spacing: AteDietCountsMetrics.gap) {
                    if let tag = row.tag {
                        AteDietChip(tag: tag)
                            .frame(minWidth: AteDietCountsMetrics.pillColumn, alignment: .leading)
                    }
                    Text(row.title)
                        .ateText(.kitDietSignal)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                    Spacer(minLength: AteDietCountsMetrics.gap)
                    HStack(spacing: AteMetrics.tight) {
                        AteIcon.feed.view(size: AteDishAggregateMetrics.peopleIcon)
                        Text(row.people).ateText(.controlSmall).monospacedDigit()
                    }
                    .foregroundStyle(palette.fg)
                }
                .accessibilityElement(children: .combine)
            }
            AteHairline()
            Text(AteDietCountsCopy.caveat)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AteDietCountsMetrics.padding)
        .frame(width: AteDietCountsMetrics.width)
    }
}

extension View {
    /// A real popover on the phone too, pointing at what opened it, rather than a sheet.
    func ateDietCountsPopover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .top) {
            content().presentationCompactAdaptation(.popover)
        }
    }
}

enum AteDietCountsCopy {
    static let caveat = "Not a guarantee. Check allergies with staff."
}

enum AteDietCountsMetrics {
    static let disc: CGFloat = 22
    static let ring: CGFloat = 1.5
    /// The 44 target spills past the 22 disc without pushing its neighbours away.
    static let hitBleed: CGFloat = (AteMetrics.hit - disc) / 2
    static let width: CGFloat = 300
    static let padding: CGFloat = 16
    static let rowGap: CGFloat = 10
    static let gap: CGFloat = 10
    /// The pills line up in a column wide enough for HALAL.
    static let pillColumn: CGFloat = 52
}

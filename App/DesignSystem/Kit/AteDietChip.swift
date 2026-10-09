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

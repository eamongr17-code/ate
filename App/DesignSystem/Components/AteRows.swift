import SwiftUI

/// **Design rule 3's "everything else"**: no container at all — a plain row parted from the next by a
/// hairline. Search results, settings, a restaurant's dishes, the radio rows in a sheet. If you are
/// reaching for a card, this is what you actually want.
struct AteListRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    /// 58 by default (`.rowcard`); `Search`'s own rows are 62 and 76, which the artboards set
    /// per list rather than globally.
    var minHeight: CGFloat = AteMetrics.rowHeight
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var action: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The design rules rows at the TOP (`border-top:1px solid var(--hair)`), so a section's
            // first row is parted from its label and its last row ends on paper, not on a line.
            AteHairline()
            HStack(spacing: AteMetrics.regular) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .ateText(.rowTitle)
                        .foregroundStyle(palette.fg)
                    if let subtitle {
                        Text(subtitle)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(minHeight: minHeight)
            .contentShape(.rect)
        }
    }
}

extension AteListRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(
            title: title, subtitle: subtitle,
            leading: { EmptyView() }, trailing: { EmptyView() }, action: action
        )
    }
}

extension AteListRow where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing, action: action)
    }
}

/// A radio row — how a sheet asks which place, which dish. A check, not a chevron: the row *is* the
/// answer, and picking it closes the question.
struct AteRadioRow: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        AteListRow(title: title, subtitle: subtitle) {
            AteRadioMark(isSelected: isSelected)
        } action: {
            action()
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The row combines its children, so its label is "name, subtitle". The identifier is the
        // name alone, which is what a drive actually wants to reach for.
        .accessibilityIdentifier("row.\(title)")
    }
}

/// The mark at the end of a radio row: a 28pt ink disc with a white check when it is the answer, and
/// a 1.5pt ring at 30% when it is not. Not a checkmark glyph in a circle — the disc is filled.
struct AteRadioMark: View {
    let isSelected: Bool

    @Environment(\.atePalette) private var palette

    private static let side: CGFloat = 28

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(palette.fg)
                AteIcon.check.view(size: 16)
                    .foregroundStyle(palette.ground)
            } else {
                Circle().strokeBorder(palette.fg.opacity(0.3), lineWidth: 1.5)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }
}

/// A chip: the small pill that carries a place, a filter, a count. 32pt, control surface, icon first.
struct AteChip: View {
    var icon: AteIcon?
    let title: String
    /// 32 by default; the feed's city chip is 40.
    var height: CGFloat = AteMetrics.chipHeight
    /// 16 by default. The place header draws its star at 14 and its people mark at 15, because a
    /// filled glyph reads heavier than a stroked one at the same box.
    var iconSize: CGFloat = 16
    var action: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let content = HStack(spacing: AteMetrics.snug - 2) {
            if let icon { icon.view(size: iconSize) }
            Text(title).ateText(.controlSmall)
        }
        .padding(.leading, icon == nil ? 12 : 10)
        .padding(.trailing, 12)
        .atePillHeight(height)
        .background(palette.chip, in: .capsule)
        .foregroundStyle(palette.fg)

        if let action {
            // A 32 (or the feed's 40) pill reaches 44 to a finger.
            let hit = AteHitOutset(height: height)
            Button(action: action) { content.ateHitArea(hit) }
                .buttonStyle(.plain)
                .ateHitFootprint(hit)
        } else {
            content
        }
    }
}

/// The one ink pill per sheet, and the Share button. 56pt, full width, foreground-on-ground inverted.
struct AteButton: View {
    var icon: AteIcon?
    let title: String
    /// 56 by default; `MainEmpty`'s is 52.
    var height: CGFloat = AteMetrics.buttonHeight
    /// `nil` fills the width it is given (a sheet's one pill). A number hugs the title with that much
    /// either side instead — `MainEmpty`'s `padding:0 28px`.
    var hugPadding: CGFloat?
    /// The quieter of two pills side by side — `SummaryFinal`'s white Done beside the ink Share: the
    /// surface's chip colour with its own foreground, where the primary is `fg` on `inverted`.
    var isSecondary = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.snug) {
                if let icon { icon.view(size: 18) }
                Text(title).ateText(.button)
            }
            .padding(.horizontal, hugPadding ?? 0)
            .frame(maxWidth: hugPadding == nil ? .infinity : nil)
            .atePillHeight(height)
            .background(isSecondary ? palette.chip : palette.fg, in: .capsule)
            .foregroundStyle(isSecondary ? palette.fg : palette.inverted)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// One choice in a segmented pill.
struct AteSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }

    var id: Value { value }
}

/// A two-way segmented pill — Journal | Saved. A pill inside a field-coloured pill, which is the only
/// segmented control the design has.
struct AteSegments<Value: Hashable>: View {
    let options: [AteSegment<Value>]
    @Binding var selection: Value

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isCurrent = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .ateText(.controlSmall)
                        .frame(maxWidth: .infinity)
                        .atePillHeight(AteMetrics.segmentHeight)
                        .background(isCurrent ? palette.chip : .clear, in: .capsule)
                        .foregroundStyle(isCurrent ? palette.fg : palette.muted)
                        .ateHitArea(Self.hitOutset)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(Self.hitOutset)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(AteMetrics.tight)
        .background(palette.field, in: .capsule)
    }

    /// A segment is drawn 36 tall; a finger gets 44 (the outset lands on the pill's own rim).
    private static var hitOutset: AteHitOutset { AteHitOutset(height: AteMetrics.segmentHeight) }
}

#if DEBUG
private struct RowsPreview: View {
    @State private var segment = 0
    @State private var picked = 1

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            AteSegments(options: [AteSegment(0, "Journal"), AteSegment(1, "Saved")], selection: $segment)
            HStack {
                AteChip(icon: .place, title: "Melbourne", action: {})
                AteChip(title: "All time")
            }
            VStack(spacing: 0) {
                AteListRow(title: "Tipo 00", subtitle: "361 Little Bourke St", action: {})
                AteRadioRow(title: "Tipo 00", subtitle: "Italian", isSelected: picked == 0) { picked = 0 }
                AteRadioRow(title: "Kisume", subtitle: "Japanese", isSelected: picked == 1) { picked = 1 }
            }
            AteButton(icon: .share, title: "Share", action: {})
        }
        .padding(AteMetrics.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .ateGround()
    }
}

#Preview("Rows and controls") { RowsPreview() }
#endif

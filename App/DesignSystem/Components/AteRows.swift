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
                Circle().fill(palette.solid)
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
    /// 12 either side by default (10 before an icon); a dish page's tag chips are `padding:0 14px`.
    var sidePadding: CGFloat = 12
    /// `.controlSmall` by default; a dish page's tag chips set 14/600 with no tracking.
    var textStyle: AteTextStyle = .controlSmall
    var action: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let content = HStack(spacing: AteMetrics.snug - 2) {
            if let icon { icon.view(size: iconSize) }
            Text(title).ateText(textStyle)
        }
        .padding(.leading, icon == nil ? sidePadding : sidePadding - 2)
        .padding(.trailing, sidePadding)
        .atePillHeight(height)
        .background(palette.raised, in: .capsule)
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
    /// Hugs its titles rather than filling the row — a segment that shares its row with other
    /// controls (round 5 exploration).
    var hugs = false
    var identifier: String?

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
                        .lineLimit(1)
                        .fixedSize(horizontal: hugs, vertical: false)
                        .padding(.horizontal, hugs ? Self.hugPadding : 0)
                        .frame(maxWidth: hugs ? nil : .infinity)
                        .atePillHeight(AteMetrics.segmentHeight)
                        .background(isCurrent ? palette.raised : .clear, in: .capsule)
                        .foregroundStyle(isCurrent ? palette.fg : palette.muted)
                        .ateHitArea(Self.hitOutset)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(Self.hitOutset)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(identifier.map { "\($0).\(option.title.lowercased())" } ?? option.title)
            }
        }
        .padding(AteMetrics.tight)
        .background(palette.field, in: .capsule)
    }

    /// A segment is drawn 36 tall; a finger gets 44 (the outset lands on the pill's own rim).
    private static var hugPadding: CGFloat { 14 }
    private static var hitOutset: AteHitOutset { AteHitOutset(height: AteMetrics.segmentHeight) }
}

import SwiftUI

/// **One answer in a sheet that picks one row** — the place sheet's places, the dish sheet's dishes.
/// The row *is* the answer: a tap picks it and the sheet closes, with no button (pattern contract §3).
/// Ruled at the top by a hairline; an optional pin before the name; a distance or count beside the
/// radio mark, whose filled disc marks the current answer.
///
/// The existing ``AteListRow`` and ``AteRadioMark``, with the sheet's anatomy decided once.
struct AteChoiceRow: View {
    let title: String
    var subtitle: String?
    /// Muted, before the mark — a distance ("350 m").
    var detail: String?
    var icon: AteIcon?
    let isSelected: Bool
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        AteListRow(
            title: title,
            subtitle: subtitle,
            leading: {
                if let icon {
                    icon.view(size: AteChoiceRowMetrics.icon)
                        .foregroundStyle(palette.fg)
                }
            },
            trailing: {
                HStack(spacing: AteMetrics.regular) {
                    if let detail {
                        Text(detail)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    AteRadioMark(isSelected: isSelected)
                }
            },
            action: action
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "row.\(title)")
    }
}

/// **The last row of a picking sheet** — "Add a new place", "Add as a new dish": a hairline, the plus
/// and the words. It opens the next step rather than answering.
struct AteAddRow: View {
    let title: String
    var isEnabled = true
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteIcon.compose.view(size: AteChoiceRowMetrics.icon)
                    Text(title).ateText(.control)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.fg)
                .frame(minHeight: AteChoiceRowMetrics.addHeight)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .accessibilityIdentifier(identifier ?? "row.add")
    }
}

/// **A group's name in a sheet** — "Best match", "Nearby", "At Tipo 00": muted meta over its rows.
struct AteSheetSectionLabel: View {
    let title: String

    @Environment(\.atePalette) private var palette

    var body: some View {
        Text(title)
            .ateText(.meta)
            .foregroundStyle(palette.muted)
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.snug)
            .accessibilityAddTraits(.isHeader)
    }
}

enum AteChoiceRowMetrics {
    /// The pin and the plus: 20.
    static let icon: CGFloat = 20
    /// The add row: `min-height:54px`.
    static let addHeight: CGFloat = 54
}

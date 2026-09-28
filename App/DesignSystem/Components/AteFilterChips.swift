import AteKit
import SwiftUI

/// **A filter chip** (round 7, `Main`) — one dimension of the filter, under the header: Newest ·
/// Rating · City · Date. At rest it is the chip colour with its name and a muted chevron, and a tap
/// opens its own small sheet. Set, it goes ink, says its value, and carries an ✕ that takes it off.
/// The same chip on the Journal, on Saved, and in the Journal's compact header.
struct AteFilterChip: View {
    let title: String
    let isActive: Bool
    var identifier: String
    let onOpen: () -> Void
    let onClear: () -> Void

    @Environment(\.atePalette) private var palette

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: isActive ? 0 : 4) {
                    Text(title)
                        .ateText(.chipLabel)
                        .lineLimit(1)
                    if isActive == false {
                        AteIcon.chevronDown.view(size: 16, lineWidth: AteFilterChipMetrics.chevronStroke)
                            .foregroundStyle(palette.muted)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, isActive ? 6 : 10)
                .frame(height: Self.height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isActive ? "On" : "")
            .accessibilityIdentifier(identifier)
            if isActive {
                Button(action: onClear) {
                    AteIcon.close.view(size: 14, lineWidth: AteFilterChipMetrics.clearStroke)
                        .padding(.trailing, 12)
                        .frame(height: Self.height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(title)")
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
        .foregroundStyle(isActive ? palette.inverted : palette.fg)
        .background(isActive ? palette.solid : palette.raised, in: .capsule)
        // A finger gets 44: the face is 36.
        .padding(.vertical, (AteMetrics.hit - Self.height) / 2)
        .contentShape(.rect)
        .padding(.vertical, -(AteMetrics.hit - Self.height) / 2)
        .fixedSize()
    }
}

enum AteFilterChipMetrics {
    /// `stroke-width: 2.2` on the chevron and `2.4` on the ✕, in Lucide's 24 box — at the icon set's
    /// optical scale.
    static let chevronStroke: CGFloat = 2.2 * AteIconShape.opticalScale
    static let clearStroke: CGFloat = 2.4 * AteIconShape.opticalScale
    /// `gap: 8px` between chips; `padding: 6px 16px 4px` around the row.
    static let spacing: CGFloat = 8
    static let top: CGFloat = 6
    static let bottom: CGFloat = 4
}

/// **The chip row** — the chips a shelf offers, in a row that scrolls sideways when the values run
/// long, on the list gutter.
struct AteFilterChipRow: View {
    let chips: [BrowseChip]
    let filters: BrowseFilters
    var cityName: String?
    var identifier = "chip"
    let onOpen: (BrowseChip) -> Void
    let onClear: (BrowseChip) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AteFilterChipMetrics.spacing) {
                ForEach(chips) { chip in
                    AteFilterChip(
                        title: filters.title(of: chip, cityName: chip == .city ? cityName : nil),
                        isActive: filters.isActive(chip),
                        identifier: "\(identifier).\(chip.rawValue)",
                        onOpen: { onOpen(chip) },
                        onClear: { onClear(chip) }
                    )
                }
            }
            .padding(.horizontal, AteMetrics.listGutter)
            .padding(.top, AteFilterChipMetrics.top)
            .padding(.bottom, AteFilterChipMetrics.bottom)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

import SwiftUI

/// **One filter in the filter sheet** — a hairline, the filter's icon and name with its live readout
/// at the right ("4.0 and up", "Any time"), and its control under them: the two-thumb range slider
/// for a range, the diet pills for tags. Nothing in the sheet pushes; there are no chevron rows.
struct AteFilterGroup<Control: View>: View {
    let icon: AteIcon
    let title: String
    let readout: String?
    @ViewBuilder var control: Control

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteFilterSheetMetrics.headerGap) {
            HStack(spacing: AteFilterSheetMetrics.labelGap) {
                icon.view(size: AteFilterSheetMetrics.icon)
                Text(title).ateText(.control)
                Spacer(minLength: AteMetrics.snug)
                if let readout {
                    Text(readout).ateText(.control).lineLimit(1)
                }
            }
            .foregroundStyle(palette.fg)
            control
        }
        .padding(.top, AteFilterSheetMetrics.sectionTop)
        .padding(.bottom, AteFilterSheetMetrics.sectionBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { AteHairline() }
    }
}

/// **A single choice inside the filter sheet** — City, Cuisine: the name left and the current value
/// right as a native `Menu`, with the up-and-down mark that says "a menu", never a push chevron.
struct AteFilterMenuRow<MenuContent: View>: View {
    let icon: AteIcon
    let title: String
    let value: String
    @ViewBuilder var menu: MenuContent

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteFilterSheetMetrics.labelGap) {
            icon.view(size: AteFilterSheetMetrics.icon)
                .foregroundStyle(palette.fg)
            Text(title).ateText(.control).foregroundStyle(palette.fg)
            Spacer(minLength: AteMetrics.snug)
            Menu {
                menu
            } label: {
                HStack(spacing: AteMetrics.tight) {
                    Text(value).ateText(.control).lineLimit(1)
                    AteIcon.chevronsUpDown.view(size: AteFilterSheetMetrics.icon)
                }
                .foregroundStyle(palette.muted)
                .frame(minHeight: AteMetrics.hit)
                .contentShape(.rect)
            }
        }
        .frame(minHeight: AteFilterSheetMetrics.menuRowHeight)
        .overlay(alignment: .top) { AteHairline() }
        .accessibilityElement(children: .combine)
    }
}

enum AteFilterSheetMetrics {
    /// `padding-top:14px` under each hairline; the slider's own air below it.
    static let sectionTop: CGFloat = 14
    static let sectionBottom: CGFloat = 6
    static let headerGap: CGFloat = 12
    /// `.slab{gap:8px}`, its icon 16; `.mrw{min-height:52px}`.
    static let labelGap: CGFloat = 8
    static let icon: CGFloat = 16
    static let menuRowHeight: CGFloat = 52
}

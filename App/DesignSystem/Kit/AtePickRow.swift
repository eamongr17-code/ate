import AteKit
import SwiftUI

/// **A dish to pick** (`lists-notifications.html` C3, "Add dishes") — one of your own dishes in a
/// sheet that ticks many: the straight thumbnail or letter tile, the dish over its place, the score
/// token only when it was scored (an unscored dish has nothing in its place — Eamon, on the page),
/// and the ink tick, empty until picked. Ruled at the top by a hairline except the first.
struct AtePickRow: View {
    let photo: AtePhoto
    let name: String
    var place: String?
    var score: AteScore?
    let isSelected: Bool
    var isFirst = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AtePickRowMetrics.gap) {
                AteThumb(photo: photo, size: .row)
                VStack(alignment: .leading, spacing: AtePickRowMetrics.lineGap) {
                    Text(name)
                        .ateText(.kitRankedDish)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AteScoreToken(score)
                AteTickMark(isOn: isSelected)
            }
            .frame(maxWidth: .infinity, minHeight: AtePickRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "pick.\(name)")
    }
}

/// **The many-pick tick** — `.chk`: a 28 ink disc with the check when on, nothing at all when off
/// (a sheet that picks one row uses ``AteRadioMark``'s ring instead).
struct AteTickMark: View {
    let isOn: Bool

    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(palette.solid)
                AteIcon.check.view(size: AtePickRowMetrics.check)
                    .foregroundStyle(palette.inverted)
            }
        }
        .frame(width: AtePickRowMetrics.tick, height: AtePickRowMetrics.tick)
        .accessibilityHidden(true)
    }
}

/// **A list to tick** (`lists-notifications.html` D2, "Add to a list") — the list's name and the
/// tick where it already holds the dish. No count (Eamon, on the page). Ruled at the top by a
/// hairline except the first.
struct AteListTickRow: View {
    let name: String
    let isOn: Bool
    var isFirst = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AtePickRowMetrics.gap) {
                Text(name)
                    .ateText(.rowTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AteTickMark(isOn: isOn)
            }
            .frame(maxWidth: .infinity, minHeight: AtePickRowMetrics.listHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "listTick.\(name)")
    }
}

enum AtePickRowMetrics {
    /// `.pk{gap:12px; min-height:66px}`; `.d{gap:2px}`.
    static let gap: CGFloat = 12
    static let height: CGFloat = 66
    static let lineGap: CGFloat = 2
    /// `.chk{width:28px; height:28px}`, its check at 16.
    static let tick: CGFloat = 28
    static let check: CGFloat = 16
    /// A list's row on the Add to a list sheet: `min-height:58px`.
    static let listHeight: CGFloat = 58
}

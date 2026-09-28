import SwiftUI

/// **A tab root's compact header** (round 6) — what comes back over the list on a scroll up, in
/// place of a second copy of the big header. Eamon: "there should be a reduced-size header variant
/// used whenever it's showing just in scrolls."
///
/// The tab's name, small, and the one control the big header carries at its end (the Feed's
/// location chip, the Journal's filter, Search's filter), in one row just under the status bar, on
/// one clean frost that runs the full width from the top of the screen and feathers out below the
/// row. The status-bar frost steps aside while it is up, so the two never stack into a heavier band
/// (build 81: heavy behind "Feed", thin under the chip).
///
/// `-ate-r6-header`: A the title centred, B the title leading with the control at the trailing end.
struct AteCompactHeader<Trailing: View>: View {
    let title: String
    var layout = AteRound6Explore.header
    @ViewBuilder var trailing: Trailing

    var body: some View {
        row
            .padding(.horizontal, AteMetrics.listGutter)
            .frame(maxWidth: .infinity)
            .frame(height: AteCompactHeaderMetrics.row)
            .background(alignment: .top) { AteCompactHeaderFrost() }
    }

    /// The trailing control's width, so a centred title keeps the same clearance on both sides and
    /// never runs under a wide control (the Feed's "Near me Melbourne" chip).
    @State private var trailingWidth: CGFloat = 0

    @ViewBuilder
    private var row: some View {
        switch layout {
        case .centred:
            ZStack {
                titleText
                    .padding(.horizontal, trailingWidth + AteMetrics.snug)
                HStack {
                    Spacer(minLength: 0)
                    trailing
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                }
            }
        case .leading:
            HStack(spacing: AteMetrics.snug) {
                titleText
                Spacer(minLength: AteMetrics.snug)
                trailing
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .ateTextLine(.compactTitle)
            .foregroundStyle(AtePalette.automatic.fg)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

enum AteCompactHeaderMetrics {
    /// The row under the status bar: the tallest control it carries (a 40 chip, a 44 hit) and air.
    static let row: CGFloat = 52
    /// How far the frost feathers out below the row.
    static let feather: CGFloat = 18
    /// The ground washed over its blur — denser than the status bar's, so a big dark title or a photo
    /// passing under it blurs to an even tone instead of a smudge (build 81: "heavy behind Feed").
    static let wash: Double = 0.84
}

/// The compact header's one frost: even, full width, from the top of the screen to the foot of the
/// row, then feathered — the status-bar frost's own material, washed denser so it reads as one even
/// surface whatever passes under it.
private struct AteCompactHeaderFrost: View {
    var body: some View {
        VStack(spacing: 0) {
            frost
            frost
                .frame(height: AteCompactHeaderMetrics.feather)
                .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
        }
        .padding(.bottom, -AteCompactHeaderMetrics.feather)
        // Up under the status bar: the header rests at the top of the safe area.
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frost: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(AteGlassColor.frostWash.opacity(AteCompactHeaderMetrics.wash))
        }
    }
}

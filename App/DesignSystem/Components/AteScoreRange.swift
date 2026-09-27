import AteKit
import SwiftUI

/// **The score range** (round 5, Eamon's pick: the ruler) — the ten half-steps from 0.5 to 5.0 as
/// ticks, the whole stars numbered under them, and the chosen span as a butter band (the score
/// colour) the ticks sit on. A finger slides the nearer end, which snaps to each half with a tick of
/// haptics.
///
/// The whole track is no filter at all; the top end on 5.0 is open, so a secret 6 clears it
/// (``ScoreBand``'s rules, tested in AteKit, and the backend's).
struct AteScoreRange: View {
    @Binding var band: ScoreBand

    @State private var dragging: ScoreBand.End?

    private var palette: AtePalette { AtePalette.surface }

    private static let height: CGFloat = 64
    private static let bandHeight: CGFloat = 36
    private static let wholeTick: CGFloat = 16
    private static let halfTick: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            header
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ruler(width: width)
                }
                .frame(width: width, height: Self.height, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(drag(width: width))
                .overlay(alignment: .topLeading) { ends(width: width) }
            }
            .frame(height: Self.height)
        }
        .sensoryFeedback(.selection, trigger: band)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.score")
    }

    /// "Score", and the range as its pill will print it — "Any" for the whole track.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text("Score")
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AteMetrics.snug)
            Text(band.title ?? "Any")
                .ateText(.controlSmall)
                .monospacedDigit()
                .foregroundStyle(palette.fg)
                .contentTransition(.numericText())
                .accessibilityIdentifier("filter.score.value")
        }
    }

    // MARK: - The ruler

    @ViewBuilder
    private func ruler(width: CGFloat) -> some View {
        let column = width / CGFloat(ScoreBand.stops)
        let low = Self.stop(band.lower)
        let high = Self.stop(band.upper)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(palette.field)
            .frame(width: width, height: Self.bandHeight)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(AteColor.butter)
            .frame(width: CGFloat(high - low + 1) * column, height: Self.bandHeight)
            .offset(x: CGFloat(low) * column)
            .scaleEffect(y: dragging == nil ? 1 : 1.06)
            .ateAnimation(AteMotion.scoreRoll, value: dragging)
        ForEach(0..<ScoreBand.stops, id: \.self) { index in
            // The whole stars are the odd stops: 1.0 is the second half-step.
            let isWhole = index.isMultiple(of: 2) == false
            let tick = isWhole ? Self.wholeTick : Self.halfTick
            Capsule()
                // Ink on butter, muted on the field — solid either way, never faded (rule 7).
                .fill(index >= low && index <= high ? AteColor.ink : palette.muted)
                .frame(width: 2, height: tick)
                .offset(x: (CGFloat(index) + 0.5) * column - 1, y: (Self.bandHeight - tick) / 2)
            if isWhole {
                Text(String((index + 1) / 2))
                    .ateText(.meta)
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .frame(width: column)
                    .offset(x: CGFloat(index) * column, y: Self.bandHeight + 6)
                    .accessibilityHidden(true)
            }
        }
    }

    /// VoiceOver's way in: the two ends, each adjustable by a half, side by side over the ruler.
    private func ends(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.modifier(EndAccessibility(band: $band, end: .lower))
            Color.clear.modifier(EndAccessibility(band: $band, end: .upper))
        }
        .frame(width: width, height: Self.bandHeight)
        .allowsHitTesting(false)
    }

    private static func stop(_ value: Double) -> Int {
        Int(((ScoreBand.snap(value) - ScoreBand.floor) / ScoreBand.step).rounded())
    }

    // MARK: - The finger

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let here = Self.score(at: value.location.x, width: width)
                let end = dragging ?? band.nearerEnd(to: Self.score(at: value.startLocation.x, width: width))
                dragging = end
                let next = band.moving(end, to: here)
                if next != band { band = next }
            }
            .onEnded { _ in dragging = nil }
    }

    /// The half-step under a point: the column it falls in.
    private static func score(at offset: CGFloat, width: CGFloat) -> Double {
        let column = width / CGFloat(ScoreBand.stops)
        let index = min(max(Int(offset / max(column, 1)), 0), ScoreBand.stops - 1)
        return ScoreBand.floor + Double(index) * ScoreBand.step
    }
}

/// One end of the range as VoiceOver meets it: "Lowest score, 3.0", swipe up or down by a half.
private struct EndAccessibility: ViewModifier {
    @Binding var band: ScoreBand
    let end: ScoreBand.End

    func body(content: Content) -> some View {
        let value = end == .lower ? band.lower : band.upper
        content
            .accessibilityElement()
            .accessibilityLabel(end == .lower ? "Lowest score" : "Highest score")
            .accessibilityValue(ScoreFormat.halfStep(value))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? ScoreBand.step : -ScoreBand.step
                band = band.moving(end, to: value + delta)
            }
            .accessibilityIdentifier(end == .lower ? "filter.score.lower" : "filter.score.upper")
    }
}

import AteKit
import SwiftUI

/// **The score range** (round 5) — two ends on the half-step track from 0.5 to 5.0, dragged with a
/// finger; the nearer end follows it and snaps to each half with a tick of haptics. The whole track
/// is no filter at all, and the top end on 5.0 is open (a secret 6 clears it) — ``ScoreBand``'s
/// rules, tested in AteKit.
///
/// Two drawings of the same control are on the table (``JSExplore/filterSheet``):
/// - **slider** — a 6pt rail in the field colour, the chosen span in ink, two ringed thumbs, and the
///   two ends printed as score tokens above it;
/// - **ruler** — the ten half-steps as ticks with the whole stars numbered under them, and the
///   chosen span as a butter band (the score colour) the ticks sit on.
struct AteScoreRange: View {
    enum Style {
        case slider, ruler
    }

    @Binding var band: ScoreBand
    var style: Style = .slider

    @State private var dragging: ScoreBand.End?

    private var palette: AtePalette { AtePalette.surface }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, style == .slider ? AteMetrics.regular : AteMetrics.snug)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    switch style {
                    case .slider: slider(width: width)
                    case .ruler: ruler(width: width)
                    }
                }
                .frame(width: width, height: trackHeight, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(drag(width: width))
            }
            .frame(height: trackHeight)
        }
        .sensoryFeedback(.selection, trigger: band)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.score")
    }

    // MARK: - The two ends, in words

    private var header: some View {
        HStack(alignment: .center, spacing: AteMetrics.snug) {
            Text("Score")
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AteMetrics.snug)
            switch style {
            case .slider:
                // The ends as the score tokens they are, en-dashed — never " · " (design rule 2).
                HStack(spacing: AteMetrics.tight + 2) {
                    ScoreToken(rating: Rating(rounding: band.lower), prose: 16)
                    Text("–")
                        .ateText(.controlSmall)
                        .foregroundStyle(palette.muted)
                    ScoreToken(rating: Rating(rounding: band.upper), prose: 16)
                }
                .accessibilityHidden(true)
            case .ruler:
                Text(band.title ?? "Any")
                    .ateText(.controlSmall)
                    .monospacedDigit()
                    .foregroundStyle(palette.fg)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 22)
    }

    // MARK: - Slider

    private static let thumb: CGFloat = 28
    private static let rail: CGFloat = 6

    private var trackHeight: CGFloat {
        style == .slider ? AteMetrics.hit : Self.rulerHeight
    }

    /// The thumbs' centres run from half a thumb in to half a thumb in, so both ends are reachable
    /// without a thumb hanging off the sheet's gutter.
    private func x(_ value: Double, width: CGFloat, inset: CGFloat) -> CGFloat {
        inset + CGFloat(ScoreBand.fraction(of: value)) * (width - 2 * inset)
    }

    @ViewBuilder
    private func slider(width: CGFloat) -> some View {
        let inset = Self.thumb / 2
        let low = x(band.lower, width: width, inset: inset)
        let high = x(band.upper, width: width, inset: inset)
        let mid = AteMetrics.hit / 2
        Capsule()
            .fill(palette.field)
            .frame(width: width, height: Self.rail)
            .offset(y: mid - Self.rail / 2)
        Capsule()
            .fill(palette.fg)
            .frame(width: max(high - low, 0) + Self.rail, height: Self.rail)
            .offset(x: low - Self.rail / 2, y: mid - Self.rail / 2)
        thumb(for: .lower)
            .offset(x: low - inset, y: mid - inset)
        thumb(for: .upper)
            .offset(x: high - inset, y: mid - inset)
    }

    private func thumb(for end: ScoreBand.End) -> some View {
        Circle()
            .fill(palette.ground)
            .overlay(Circle().strokeBorder(palette.fg, lineWidth: 2))
            .frame(width: Self.thumb, height: Self.thumb)
            .scaleEffect(dragging == end ? 1.12 : 1)
            .ateAnimation(AteMotion.scoreRoll, value: dragging)
            .modifier(EndAccessibility(band: $band, end: end))
    }

    // MARK: - Ruler

    private static let rulerHeight: CGFloat = 64
    private static let bandHeight: CGFloat = 36

    @ViewBuilder
    private func ruler(width: CGFloat) -> some View {
        // Ten columns, one per half-step; a tick stands in the middle of each.
        let column = width / CGFloat(ScoreBand.stops)
        let lowIndex = stopIndex(band.lower)
        let highIndex = stopIndex(band.upper)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(palette.field)
            .frame(width: width, height: Self.bandHeight)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(AteColor.butter)
            .frame(width: CGFloat(highIndex - lowIndex + 1) * column, height: Self.bandHeight)
            .offset(x: CGFloat(lowIndex) * column)
        ForEach(0..<ScoreBand.stops, id: \.self) { index in
            let isWhole = index.isMultiple(of: 2) == false
            let isIn = index >= lowIndex && index <= highIndex
            Capsule()
                .fill(isIn ? AteColor.ink : palette.muted)
                .frame(width: 2, height: isWhole ? 16 : 8)
                .offset(
                    x: (CGFloat(index) + 0.5) * column - 1,
                    y: (Self.bandHeight - (isWhole ? 16 : 8)) / 2
                )
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
        Color.clear
            .frame(width: width, height: Self.bandHeight)
            .modifier(EndAccessibility(band: $band, end: .lower))
        Color.clear
            .frame(width: width, height: Self.bandHeight)
            .modifier(EndAccessibility(band: $band, end: .upper))
    }

    private func stopIndex(_ value: Double) -> Int {
        Int(((ScoreBand.snap(value) - ScoreBand.floor) / ScoreBand.step).rounded())
    }

    // MARK: - The finger

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let here = score(at: value.location.x, width: width)
                let end = dragging ?? band.nearerEnd(to: score(at: value.startLocation.x, width: width))
                dragging = end
                let next = band.moving(end, to: here)
                if next != band { band = next }
            }
            .onEnded { _ in dragging = nil }
    }

    private func score(at offset: CGFloat, width: CGFloat) -> Double {
        switch style {
        case .slider:
            let inset = Self.thumb / 2
            return ScoreBand.value(atFraction: Double((offset - inset) / max(width - 2 * inset, 1)))
        case .ruler:
            let column = width / CGFloat(ScoreBand.stops)
            let index = min(max(Int(offset / column), 0), ScoreBand.stops - 1)
            return ScoreBand.floor + Double(index) * ScoreBand.step
        }
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

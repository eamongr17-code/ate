import AteKit
import SwiftUI

/// **A two-thumb range slider** (round 7 — Eamon: a traditional slider, not the ruler) — a thin
/// track, the chosen span filled between two round thumbs, the scale's labels under it. A finger
/// picks up the nearer thumb and slides it; it snaps to each stop with a tick of haptics, and the two
/// never cross. The rating and the date sheets both draw it (``AteScoreRangeSlider``,
/// ``AteMonthRangeSlider``).
struct AteRangeSlider: View {
    /// How many stops the track has; the ends are indices into them.
    let stops: Int
    @Binding var lower: Int
    @Binding var upper: Int
    /// Under the track: a stop and what it reads.
    var labels: [(stop: Int, text: String)] = []
    /// VoiceOver's reading of a stop.
    let valueText: (Int) -> String
    var lowerName = "From"
    var upperName = "To"
    var identifier: String

    @Environment(\.atePalette) private var palette
    @State private var dragging: ScoreBand.End?

    var body: some View {
        VStack(spacing: AteRangeSliderMetrics.labelGap) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.field)
                        .frame(height: AteRangeSliderMetrics.track)
                    Capsule()
                        .fill(AteColor.butter)
                        .frame(width: max(x(upper, width) - x(lower, width), 0) + AteRangeSliderMetrics.track,
                               height: AteRangeSliderMetrics.track)
                        .offset(x: x(lower, width) - AteRangeSliderMetrics.track / 2)
                    thumb(.lower).offset(x: x(lower, width) - AteRangeSliderMetrics.thumb / 2)
                    thumb(.upper).offset(x: x(upper, width) - AteRangeSliderMetrics.thumb / 2)
                }
                .frame(width: width, height: AteMetrics.hit)
                .contentShape(.rect)
                .gesture(drag(width: width))
                .overlay { ends }
            }
            .frame(height: AteMetrics.hit)
            if labels.isEmpty == false {
                GeometryReader { proxy in
                    ForEach(labels, id: \.stop) { label in
                        Text(label.text)
                            .ateText(.sliderLabel)
                            .monospacedDigit()
                            .foregroundStyle(palette.muted)
                            .fixedSize()
                            .position(x: labelX(label.stop, proxy.size.width), y: proxy.size.height / 2)
                    }
                }
                .frame(height: AteRangeSliderMetrics.labelHeight)
                .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.selection, trigger: lower)
        .sensoryFeedback(.selection, trigger: upper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func thumb(_ end: ScoreBand.End) -> some View {
        Circle()
            .fill(AteRangeSliderMetrics.thumbFill)
            .overlay { Circle().strokeBorder(palette.hairline, lineWidth: 0.5) }
            .frame(width: AteRangeSliderMetrics.thumb, height: AteRangeSliderMetrics.thumb)
            .shadow(color: AteRangeSliderMetrics.thumbShadow, radius: 3, y: 1)
            .scaleEffect(dragging == end ? 1.1 : 1)
            .ateAnimation(AteMotion.scoreRoll, value: dragging)
    }

    /// A stop's centre along the track. The thumbs stay inside it: the first and last stops sit a
    /// thumb's radius in from its ends.
    private func x(_ stop: Int, _ width: CGFloat) -> CGFloat {
        let inset = AteRangeSliderMetrics.thumb / 2
        guard stops > 1 else { return inset }
        return inset + CGFloat(stop) / CGFloat(stops - 1) * (width - 2 * inset)
    }

    /// Labels are laid across the whole width, so the end ones hug the track's ends.
    private func labelX(_ stop: Int, _ width: CGFloat) -> CGFloat { x(stop, width) }

    private func stop(at location: CGFloat, width: CGFloat) -> Int {
        let inset = AteRangeSliderMetrics.thumb / 2
        let fraction = (location - inset) / max(width - 2 * inset, 1)
        return min(max(Int((fraction * CGFloat(stops - 1)).rounded()), 0), stops - 1)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let here = stop(at: value.location.x, width: width)
                let end = dragging ?? nearer(to: stop(at: value.startLocation.x, width: width))
                dragging = end
                switch end {
                case .lower: if min(here, upper) != lower { lower = min(here, upper) }
                case .upper: if max(here, lower) != upper { upper = max(here, lower) }
                }
            }
            .onEnded { _ in dragging = nil }
    }

    /// The thumb a touch picks up: the nearer; on a tie (the thumbs together), the one with room to
    /// move that way.
    private func nearer(to stop: Int) -> ScoreBand.End {
        let toLower = abs(stop - lower)
        let toUpper = abs(stop - upper)
        if toLower == toUpper { return stop < lower ? .lower : .upper }
        return toLower < toUpper ? .lower : .upper
    }

    /// VoiceOver's way in: the two thumbs, each adjustable a stop at a time.
    private var ends: some View {
        HStack(spacing: 0) {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(lowerName)
                .accessibilityValue(valueText(lower))
                .accessibilityAdjustableAction { direction in
                    lower = min(max(lower + (direction == .increment ? 1 : -1), 0), upper)
                }
                .accessibilityIdentifier("\(identifier).lower")
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(upperName)
                .accessibilityValue(valueText(upper))
                .accessibilityAdjustableAction { direction in
                    upper = max(min(upper + (direction == .increment ? 1 : -1), stops - 1), lower)
                }
                .accessibilityIdentifier("\(identifier).upper")
        }
        .allowsHitTesting(false)
    }
}

enum AteRangeSliderMetrics {
    /// The track's thickness and the thumbs' diameter.
    static let track: CGFloat = 6
    static let thumb: CGFloat = 28
    /// The labels, 10 under the track's hit row (`margin-top: -10px` on the artboard's 20 gap).
    static let labelGap: CGFloat = 4
    static let labelHeight: CGFloat = 18
    /// A thumb is white in both modes — a knob, not a surface — lifted by a close shadow.
    static let thumbFill = Color.white
    static let thumbShadow = AteColor.ink.opacity(0.22)
}

/// **The rating's range**: 0.5 … 5.0 in halves, then the secret 6; the whole numbers labelled.
struct AteScoreRangeSlider: View {
    @Binding var band: ScoreBand

    var body: some View {
        AteRangeSlider(
            stops: ScoreBand.stops,
            lower: Binding(
                get: { ScoreBand.index(of: band.lower) },
                set: { band = ScoreBand(lower: ScoreBand.values[$0], upper: band.upper) }
            ),
            upper: Binding(
                get: { ScoreBand.index(of: band.upper) },
                set: { band = ScoreBand(lower: band.lower, upper: ScoreBand.values[$0]) }
            ),
            labels: ScoreBand.values.enumerated()
                .filter { $0.element == $0.element.rounded() }
                .map { (stop: $0.offset, text: String(Int($0.element))) },
            valueText: { ScoreFormat.halfStep(ScoreBand.values[$0]) },
            lowerName: "Lowest score",
            upperName: "Highest score",
            identifier: "filter.score"
        )
    }
}

/// **The months' range**: the last two years, this month on the right; either end at the track's end
/// is open ("from the beginning", "up to today"). Each January carries its year.
struct AteMonthRangeSlider: View {
    @Binding var window: DateWindow
    var now = Date()

    private var months: [AteMonth] { DateWindow.rulerMonths(now: now) }

    var body: some View {
        let months = months
        let stops = window.rulerStops(months: months)
        AteRangeSlider(
            stops: months.count,
            lower: Binding(
                get: { stops.lower },
                set: {
                    let upper = window.rulerStops(months: months).upper
                    window = DateWindow.fromRuler(lower: $0, upper: upper, months: months)
                }
            ),
            upper: Binding(
                get: { stops.upper },
                set: {
                    let lower = window.rulerStops(months: months).lower
                    window = DateWindow.fromRuler(lower: lower, upper: $0, months: months)
                }
            ),
            labels: months.enumerated()
                .filter { $0.element.month == 1 }
                .map { (stop: $0.offset, text: String($0.element.year)) },
            valueText: { months.indices.contains($0) ? "\(months[$0].shortName()) \(months[$0].year)" : "" },
            identifier: "filter.date"
        )
    }
}

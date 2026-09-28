import AteKit
import SwiftUI

/// **Round 6 exploration: the date filter** — `-ate-r6-date A|B` picks a layout at launch so each
/// can be photographed for Eamon. Absent (and in any Release build) is A. Goes once he picks.
enum DateExplore {
    enum Variant: String { case ruler = "A", presets = "B" }

    static var variant: Variant {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-ate-r6-date"), arguments.indices.contains(index + 1) {
            return Variant(rawValue: arguments[index + 1].uppercased()) ?? .ruler
        }
        #endif
        return .ruler
    }
}

/// **The date range** (round 6, Eamon: "filters need to have a date range slider") — in the score
/// ruler's family: a butter band over ticks, dragged by its nearer end, snapping with a tick of
/// haptics. Here the stops are **months**: the last two years, this month on the right. The ruler's
/// two ends are open — the left stop is "from the beginning", the right "up to today" — so the whole
/// ruler is no filter.
///
/// Two layouts are on the table (``DateExplore``):
/// - **A** — the month ruler on its own;
/// - **B** — four quick choices (This month, 3 mo, This year, All) as pills, and a fifth, Custom,
///   that opens the same ruler under them.
struct AteDateRange: View {
    @Binding var window: DateWindow
    var variant: DateExplore.Variant = DateExplore.variant
    var now = Date()

    @State private var isCustom = false
    @State private var dragging: ScoreBand.End?

    private var palette: AtePalette { AtePalette.surface }
    private var months: [AteMonth] { DateWindow.rulerMonths(now: now) }

    private static let height: CGFloat = 64
    private static let bandHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            header
            switch variant {
            case .ruler:
                ruler
            case .presets:
                presets
                if isCustom { ruler }
            }
        }
        .sensoryFeedback(.selection, trigger: window)
        .onAppear {
            // A window that is not one of the quick choices opens on the ruler.
            isCustom = window.isAll == false && window.preset(now: now) == nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter.date")
    }

    /// "When", and the window as its pill will print it — "Any time" for none.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text("When")
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AteMetrics.snug)
            Text(window.title(now: now) ?? "Any time")
                .ateText(.controlSmall)
                .foregroundStyle(palette.fg)
                .contentTransition(.numericText())
                .accessibilityIdentifier("filter.date.value")
        }
    }

    // MARK: - B: the quick choices

    private var presets: some View {
        AteFlow(spacing: AteMetrics.snug) {
            ForEach(DateWindow.Preset.allCases, id: \.self) { preset in
                AteFilterChoice(
                    title: preset.title,
                    isOn: isCustom == false && window.preset(now: now) == preset
                ) {
                    isCustom = false
                    window = DateWindow.preset(preset, now: now)
                }
                .accessibilityIdentifier("date.\(preset.rawValue)")
            }
            AteFilterChoice(title: "Custom", isOn: isCustom) {
                isCustom = true
            }
            .accessibilityIdentifier("date.custom")
        }
    }

    // MARK: - The month ruler

    private var ruler: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                track(width: width)
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(drag(width: width))
            .overlay(alignment: .topLeading) { ends(width: width) }
        }
        .frame(height: Self.height)
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let column = width / CGFloat(months.count)
        let stops = window.rulerStops(months: months)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(palette.field)
            .frame(width: width, height: Self.bandHeight)
        RoundedRectangle(cornerRadius: AteMetrics.pill)
            .fill(AteColor.butter)
            .frame(width: CGFloat(stops.upper - stops.lower + 1) * column, height: Self.bandHeight)
            .offset(x: CGFloat(stops.lower) * column)
            .scaleEffect(y: dragging == nil ? 1 : 1.06)
            .ateAnimation(AteMotion.scoreRoll, value: dragging)
        ForEach(Array(months.enumerated()), id: \.offset) { index, month in
            // A January stands taller, and carries its year under it.
            let isYear = month.month == 1
            let tick: CGFloat = isYear ? 16 : 8
            Capsule()
                // Ink on butter, muted on the field — solid either way, never faded.
                .fill(index >= stops.lower && index <= stops.upper ? AteColor.ink : palette.muted)
                .frame(width: 2, height: tick)
                .offset(x: (CGFloat(index) + 0.5) * column - 1, y: (Self.bandHeight - tick) / 2)
            if isYear || index == months.count - 1 {
                Text(isYear ? String(month.year) : month.shortName())
                    .ateText(.meta)
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .fixedSize()
                    .frame(width: column * 4)
                    .offset(x: (CGFloat(index) + 0.5) * column - column * 2, y: Self.bandHeight + 6)
                    .accessibilityHidden(true)
            }
        }
    }

    /// VoiceOver's way in: the two ends, each adjustable by a month.
    private func ends(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.modifier(MonthEnd(window: $window, end: .lower, months: months))
            Color.clear.modifier(MonthEnd(window: $window, end: .upper, months: months))
        }
        .frame(width: width, height: Self.bandHeight)
        .allowsHitTesting(false)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let here = stop(at: value.location.x, width: width)
                let stops = window.rulerStops(months: months)
                let start = stop(at: value.startLocation.x, width: width)
                let end = dragging ?? (abs(start - stops.lower) <= abs(start - stops.upper) ? .lower : .upper)
                dragging = end
                let lower = end == .lower ? min(here, stops.upper) : stops.lower
                let upper = end == .upper ? max(here, stops.lower) : stops.upper
                let next = DateWindow.fromRuler(lower: lower, upper: upper, months: months)
                if next != window { window = next }
            }
            .onEnded { _ in dragging = nil }
    }

    private func stop(at offset: CGFloat, width: CGFloat) -> Int {
        let column = width / CGFloat(max(months.count, 1))
        return min(max(Int(offset / max(column, 1)), 0), months.count - 1)
    }
}

/// One end of the month ruler as VoiceOver meets it: "From, March 2026", swipe up or down by a month.
private struct MonthEnd: ViewModifier {
    @Binding var window: DateWindow
    let end: ScoreBand.End
    let months: [AteMonth]

    func body(content: Content) -> some View {
        let stops = window.rulerStops(months: months)
        let index = end == .lower ? stops.lower : stops.upper
        let month = months.indices.contains(index) ? months[index] : nil
        content
            .accessibilityElement()
            .accessibilityLabel(end == .lower ? "From" : "To")
            .accessibilityValue(month.map { "\($0.shortName()) \($0.year)" } ?? "")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1 : -1
                let lower = end == .lower ? min(max(stops.lower + step, 0), stops.upper) : stops.lower
                let upper = end == .upper ? max(min(stops.upper + step, months.count - 1), stops.lower) : stops.upper
                window = DateWindow.fromRuler(lower: lower, upper: upper, months: months)
            }
            .accessibilityIdentifier(end == .lower ? "filter.date.from" : "filter.date.to")
    }
}

import AteKit
import SwiftUI

/// **Scoring is a finger slide, not taps** (design rule 7).
///
/// Five 44pt stars in equal columns, ten half-step zones across them, and the thumb drags through
/// the value: the star under the finger is the one that fills, and the numeral rolls as it crosses
/// each half. Stars are solid outlines at full strength — never low-opacity — so an unscored star
/// reads as "nothing here yet" rather than as a disabled control.
///
/// The position→score arithmetic is `AteKit.RatingTrack`, ported with its tests: the zone maths is the
/// part that can be wrong in a way no screenshot shows (whether the leading edge means 0.5, whether
/// the last pixel is reachable as 5.0, whether a tap and a drag agree).
struct StarSlider: View {
    /// What is being scored — the dish, named in the person's own words.
    let dishName: String
    @Binding var rating: Rating?
    /// Fired when the finger lifts, so a caller can close the panel or write the token.
    var onFinish: ((Rating) -> Void)?

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var trackWidth: CGFloat = 0
    /// True while a finger is on the track. SwiftUI resets it however the drag ends — lifted *or*
    /// cancelled (a system gesture, a second finger) — and a cancelled drag never reaches `onEnded`.
    /// Watching the reset is what stops a cancelled scrub leaving the panel up with no way out.
    @GestureState private var isScrubbing = false

    /// Design rule 7: an unscored dish is an empty star and NO text. Five empty stars already say
    /// it; a dash would be the app putting words in someone's mouth.
    private var score: some View {
        Text(rating.map { ScoreFormat.halfStep($0.value) } ?? "")
            .ateText(.sliderScore)
            .monospacedDigit()
            .fixedSize()
            .contentTransition(.numericText(value: rating?.value ?? 0))
            .ateAnimation(AteMotion.scoreRoll, value: rating?.halfSteps ?? 0)
    }

    /// `RaterSize.dc.html` (2026-09-26): the dish and its score on one scale — the name in the
    /// slip's dish voice at 22, the numeral at 28, baselines shared, `gap:14px`; the panel
    /// `padding:18px 18px 16px; gap:12px`.
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            if dynamicTypeSize.isAccessibilitySize {
                // At the accessibility sizes the name beside a 28pt-and-up numeral has a word's
                // width and broke mid-word ("Tagliatell / e"): it takes the panel's width, never
                // breaking a word (``WordFittingLabel``), with the score under it.
                AteExactText(text: dishName, style: .sliderDish, alignment: .leading, lineLimit: 2)
                score
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Self.headerGap) {
                    Text(dishName)
                        .ateText(.sliderDish)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    score
                }
            }
            track
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, AteMetrics.loose)
        // `box-shadow:0 0 0 1.5px #24141F, 0 18px 40px -18px rgba(36,20,31,.45)` — a hairline ring
        // and a shadow tight under the panel, not a halo around it.
        .ateBackground(
            palette.chip,
            in: RoundedRectangle(cornerRadius: AteMetrics.panel, style: .continuous),
            shadow: .panel
        )
        .overlay {
            RoundedRectangle(cornerRadius: AteMetrics.panel, style: .continuous)
                .strokeBorder(palette.fg, lineWidth: 1.5)
        }
    }

    /// `gap:14px` between the name and the numeral.
    private static let headerGap: CGFloat = 14

    private var track: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                AteStar(fill: fill(forStarAt: index))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: AteMetrics.starTrack)
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .gesture(scrub)
        .onChange(of: isScrubbing) { wasScrubbing, scrubbing in
            guard wasScrubbing, scrubbing == false, let rating else { return }
            onFinish?(rating)
        }
        .accessibilityElement()
        .accessibilityLabel("Score for \(dishName)")
        .accessibilityValue(RatingTrack.accessibilityValue(rating))
        .accessibilityAdjustableAction { direction in
            let next = RatingTrack.adjusted(rating, by: direction == .increment ? 1 : -1)
            rating = next
            onFinish?(next)
        }
    }

    /// How much of the star at `index` is filled: 1, 0.5, or 0.
    private func fill(forStarAt index: Int) -> Double {
        guard let rating else { return 0 }
        let halves = rating.halfSteps - index * 2
        return switch halves {
        case ...0: 0
        case 1: 0.5
        default: 1
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isScrubbing) { _, scrubbing, _ in scrubbing = true }
            .onChanged { value in
                let next = RatingTrack.rating(atX: Double(value.location.x), trackWidth: Double(trackWidth))
                guard next != rating else { return }
                rating = next
                AteHaptics.tick()
            }
            .onEnded { value in
                let next = RatingTrack.rating(atX: Double(value.location.x), trackWidth: Double(trackWidth))
                rating = next
                onFinish?(next)
            }
    }
}

/// The one place that asks the phone to make something felt. A *selection* generator, not an impact
/// one: a score crossing a half-step is a value changing, which is exactly what `selectionChanged`
/// means — and it is the lightest thing the Taptic Engine does, which matters when one scrub crosses
/// nine of them.
@MainActor
enum AteHaptics {
    private static let selection = UISelectionFeedbackGenerator()

    static func tick() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// A save landing. An *impact*, not a selection: a bookmark is a thing put on a shelf, and it is
    /// one tap rather than nine in a scrub, so it can afford to be felt.
    static func save() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A key that had nothing to act on — the Diet key with no dish before the caret. The system's
    /// own error pattern, the lightest thing that says "not here" without a word of copy.
    static func refused() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// An entry saved — Done in the composer landing. The system's own success pattern.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

#if DEBUG
private struct StarSliderPreview: View {
    @State private var rating: Rating? = Rating(rounding: 4.5)
    @State private var unrated: Rating?

    var body: some View {
        VStack(spacing: AteMetrics.section) {
            StarSlider(dishName: "Tagliatelle al ragù", rating: $rating)
            StarSlider(dishName: "Prawn spaghetti", rating: $unrated)
        }
        .padding(AteMetrics.gutter)
        .frame(maxHeight: .infinity)
        .ateGround()
    }
}

#Preview("Star slider") { StarSliderPreview() }
#endif

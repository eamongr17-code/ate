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
///
/// **The secret 6** (round 4, ``allowsSix``): a finger dragged past 5.0 meets slight resistance — the
/// stars follow it on a rubber band — and held out there for a second the haptic builds until a
/// sixth star comes out in the special colour with a small burst. No label. With Reduce Motion the
/// star simply appears in its colour. The distance-and-time rules are `AteKit.SecretSix`.
struct StarSlider: View {
    /// What is being scored — the dish, named in the person's own words.
    let dishName: String
    @Binding var rating: Rating?
    /// The composer's slider can reach the secret 6; nothing else offers it.
    var allowsSix = false
    /// Fired when the finger lifts, so a caller can close the panel or write the token.
    var onFinish: ((Rating) -> Void)?

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trackWidth: CGFloat = 0
    /// True while a finger is on the track. SwiftUI resets it however the drag ends — lifted *or*
    /// cancelled (a system gesture, a second finger) — and a cancelled drag never reaches `onEnded`.
    /// Watching the reset is what stops a cancelled scrub leaving the panel up with no way out.
    @GestureState private var isScrubbing = false
    @State private var six = SecretSix()
    /// How far the stars follow a finger past the end (the rubber band).
    @State private var stretch: CGFloat = 0
    /// The charge building while the finger holds past the end.
    @State private var charging: Task<Void, Never>?
    /// Bumped each time the sixth star comes out — the burst's trigger.
    @State private var bursts = 0

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
        .onAppear { six.reset(to: rating) }
        .onDisappear { charging?.cancel() }
    }

    /// `gap:14px` between the name and the numeral.
    private static let headerGap: CGFloat = 14

    /// Five stars — six once the secret is out, the sixth in the special colour.
    private var showsSix: Bool { rating == .blownAway }

    private var track: some View {
        // The stars are drawn in their own row, which the rubber band moves; the gesture is read off
        // the still frame around them, so the zones never slide under the finger.
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                AteStar(fill: fill(forStarAt: index))
                    .frame(maxWidth: .infinity)
            }
            if showsSix {
                SixthStar(bursts: bursts)
                    .frame(maxWidth: .infinity)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .offset(x: stretch)
        .ateAnimation(.spring(duration: 0.35, bounce: 0.35), value: showsSix)
        .frame(height: AteMetrics.starTrack)
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .gesture(scrub)
        .onChange(of: isScrubbing) { wasScrubbing, scrubbing in
            guard wasScrubbing, scrubbing == false else { return }
            // However the finger left — lifted or cancelled — the band springs home and an
            // unfinished charge is dropped.
            letGo()
            guard let rating else { return }
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
                let fingerX = Double(value.location.x)
                if allowsSix { follow(x: fingerX) }
                let next = six.rating(onTrack: RatingTrack.rating(atX: fingerX, trackWidth: Double(trackWidth)))
                guard next != rating else { return }
                rating = next
                AteHaptics.tick()
            }
            .onEnded { value in
                let fingerX = Double(value.location.x)
                let next = six.rating(onTrack: RatingTrack.rating(atX: fingerX, trackWidth: Double(trackWidth)))
                rating = next
                letGo()
                onFinish?(next)
            }
    }

    // MARK: - The secret 6

    /// The finger moved: the rubber band follows it, and crossing out past the end starts the charge
    /// (crossing back stops it).
    private func follow(x fingerX: Double) {
        let overshoot = SecretSix.overshoot(x: fingerX, trackWidth: Double(trackWidth))
        stretch = reduceMotion ? 0 : CGFloat(SecretSix.stretch(overshoot: overshoot))
        let wasUnlocked = six.isUnlocked
        guard six.move(x: fingerX, trackWidth: Double(trackWidth), at: Self.now) else { return }
        if case .charging = six.phase {
            startCharging()
        } else {
            charging?.cancel()
            charging = nil
            // Let go of a 6 by dragging back inside: the ordinary slider again.
            if wasUnlocked, six.isUnlocked == false {
                rating = RatingTrack.rating(atX: fingerX, trackWidth: Double(trackWidth))
            }
        }
    }

    /// The hold: a tap that grows every tenth of a second, then the sixth star.
    private func startCharging() {
        charging?.cancel()
        charging = Task { @MainActor in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(90))
                guard Task.isCancelled == false, let progress = six.tick(at: Self.now) else { return }
                if six.isUnlocked {
                    AteHaptics.blownAway()
                    rating = .blownAway
                    bursts += 1
                    return
                }
                AteHaptics.charge(progress)
            }
        }
    }

    private func letGo() {
        charging?.cancel()
        charging = nil
        six.lift()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3)) { stretch = 0 }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The sixth star: filled in the special colour (`ScoreStyle.sixthStar`), and — each time it comes
/// out, motion allowing — a small burst of dots from its centre.
private struct SixthStar: View {
    let bursts: Int

    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1

    var body: some View {
        ZStack {
            if reduceMotion == false {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Angle.degrees(Double(index) * 45 + 22.5)
                    Circle()
                        .fill(index.isMultiple(of: 2) ? ScoreStyle.sixthStar : AteColor.scoreMark)
                        .frame(width: 5, height: 5)
                        .offset(
                            x: cos(angle.radians) * (12 + 22 * progress),
                            y: sin(angle.radians) * (12 + 22 * progress)
                        )
                        .opacity(1 - progress)
                }
            }
            ZStack {
                AteIconShape(paths: AteIcon.starFilled.fills)
                    .fill(ScoreStyle.sixthStar)
                AteIconShape(paths: AteIcon.star.strokes)
                    .stroke(style: StrokeStyle(
                        lineWidth: 1.3 * AteMetrics.star / AteVector.viewBox, lineCap: .round, lineJoin: .round
                    ))
                    .foregroundStyle(palette.fg)
            }
            .frame(width: AteMetrics.star, height: AteMetrics.star)
        }
        .onAppear { burst() }
        .onChange(of: bursts) { _, _ in burst() }
        .accessibilityHidden(true)
    }

    private func burst() {
        guard reduceMotion == false else { return }
        progress = 0
        withAnimation(.easeOut(duration: 0.6)) { progress = 1 }
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
        key()
    }

    /// **A key pressed** — the Score, Place and Diet keys, a diet code, the `+`, and a bookmark (``save()``
    /// is this): one light impact, so the same kind of tap feels the same everywhere (round 4).
    static func key() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The secret 6 building under a held finger: taps that grow, `progress` 0…1.
    static func charge(_ progress: Double) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.25 + 0.75 * min(1, max(0, progress)))
    }

    /// …and the sixth star coming out.
    static func blownAway() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

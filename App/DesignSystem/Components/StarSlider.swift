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
///
/// **None left** (``sixLock``, 25 Oct: two 6s in any two months): the same reach and hold, but the
/// sixth star comes out as a dashed outline with one soft tap and no burst, the word line says when
/// the next comes back, and the score stays 5.0.
struct StarSlider: View {
    /// What is being scored — the dish, named in the person's own words. Heard by VoiceOver only;
    /// the panel shows the score's word.
    let dishName: String
    @Binding var rating: Rating?
    /// The composer's slider can reach the secret 6; nothing else offers it.
    var allowsSix = false
    /// Set when no 6 is left to give: past 5.0 is a locked outline, and the score stays 5.0.
    var sixLock: SixLock?
    /// The sixth star came out locked.
    var onSixLocked: (() -> Void)?
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

    /// The plain word for the score (``Rating/word``), live as the finger slides — never the
    /// person's own words, which the last-words guess often got wrong (Eamon, 18 Oct,
    /// `design/rebuild/rating-words.html` option A). Unscored it is empty like the numeral, but a
    /// space holds the line so the panel doesn't jump on the first touch.
    private var word: String {
        if isLockedOut, let sixLock { return sixLock.word() }
        return rating?.word ?? " "
    }

    /// `RaterSize.dc.html` (2026-09-26), rebalanced for the word (18 Oct): the word in the dish
    /// voice a step down at 20 on one line, the numeral at 28, baselines shared, `gap:14px`; the
    /// panel `padding:18px 18px 16px; gap:12px`.
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            if dynamicTypeSize.isAccessibilitySize {
                // At the accessibility sizes a long word beside a 28pt-and-up numeral has no room:
                // it takes the panel's width, never breaking a word (``WordFittingLabel``), with
                // the score under it.
                AteExactText(text: word, style: .sliderWord, alignment: .leading, lineLimit: 2)
                score
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Self.headerGap) {
                    Text(word)
                        .ateText(.sliderWord)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .ateAnimation(AteMotion.scoreRoll, value: rating?.halfSteps ?? 0)
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
    /// Held out past 5.0 with no 6 left to give.
    private var isLockedOut: Bool { sixLock != nil && six.isUnlocked }

    /// What a reach past the end may score: a 6, unless none is left.
    private func allowed(_ next: Rating) -> Rating {
        sixLock != nil && next == .blownAway ? .perfect : next
    }

    /// The score under a finger at `fingerX` — a 6 once unlocked, unless none is left.
    private func trackRating(atX fingerX: Double) -> Rating {
        allowed(six.rating(onTrack: RatingTrack.rating(atX: fingerX, trackWidth: Double(trackWidth))))
    }

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
            } else if isLockedOut {
                LockedSixthStar()
                    .frame(maxWidth: .infinity)
                    .transition(reduceMotion ? .identity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .offset(x: stretch)
        .ateAnimation(.spring(duration: 0.35, bounce: 0.35), value: showsSix)
        .ateAnimation(.spring(duration: 0.35, bounce: 0.2), value: isLockedOut)
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
                let next = trackRating(atX: fingerX)
                guard next != rating else { return }
                rating = next
                AteHaptics.tick()
            }
            .onEnded { value in
                let fingerX = Double(value.location.x)
                let next = trackRating(atX: fingerX)
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
                if six.isUnlocked, sixLock != nil {
                    AteHaptics.sixLocked()
                    rating = .perfect
                    onSixLocked?()
                    return
                }
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

/// The sixth star when none is left: an outline, dashed and quiet, with nothing in it.
private struct LockedSixthStar: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        AteIconShape(paths: AteIcon.star.strokes)
            .stroke(style: StrokeStyle(
                lineWidth: 1.3 * AteMetrics.star / AteVector.viewBox,
                lineCap: .round, lineJoin: .round, dash: [2.4, 2.2]
            ))
            .foregroundStyle(palette.muted)
            .frame(width: AteMetrics.star, height: AteMetrics.star)
            .accessibilityHidden(true)
    }
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

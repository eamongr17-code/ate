import AteKit
import SwiftUI
import UIKit

/// **Custom surface #1** — the half-star scrub (§2).
///
/// The whole product's friction budget lives here: rating a dish must cost one thumb movement, with
/// no keyboard, no picker wheel and no confirmation. Three decisions make that true:
///
/// 1. **A tap and a scrub are the same code path**, so they can never disagree about what 3.5 means
///    (§2.3). Which one it was is reported honestly on `log_rating_set(method:)`.
/// 2. **No animation while the finger is down.** The fill tracks the thumb 1:1; an animated fill
///    lags the finger and reads as lag, not polish (§2.3).
/// 3. **The mapping is not in this file.** ``RatingTrack`` owns the arithmetic and is unit-tested;
///    this view owns pixels, haptics and accessibility.
/// 4. **The gesture is not a `DragGesture`.** It is ``RatingScrubGesture``, which axis-locks against
///    the enclosing `List` — see that file for the device failure this fixed.
struct RatingControl: View {
    @Binding var rating: Rating?
    /// Fires on every settled change, with how it was made — `log_rating_set(value, method)`.
    var onChange: (Rating, LogRatingMethod) -> Void = { _, _ in }
    /// Bumped by the host to run the §2.4 invalid-on-post wiggle.
    var wiggleTrigger: Int = 0

    /// §2.4: the hint disappears permanently after the first-ever successful rating. One shot, for
    /// the whole app, forever — a hint that returns is an ad.
    @AppStorage("log.hasRatedOnce") private var hasRatedOnce = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The value the current touch started from, and the flag that says a touch is live at all.
    /// `Rating??` is deliberate: `.some(nil)` is "scrubbing, from unrated".
    @State private var scrubStartValue: Rating??

    /// §6's motion moment #1 — **the app's signature**. Bumped on finger lift; the star row settles
    /// with a 0.28s spring. Deliberately a trigger and not a state the gesture animates: the scrub
    /// itself has to stay 1:1 with the thumb (§2.3), so the ONLY animated instant is the release.
    @State private var settleTrigger = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if dynamicTypeSize.isAccessibilitySize {
                // §2.5: at accessibility sizes the track gets its own row above the readout, so the
                // glyphs can grow without squeezing the number off the card.
                track
                readout
            } else {
                HStack(spacing: Theme.Spacing.regular) {
                    track
                    readout
                }
            }

            if !hasRatedOnce && rating == nil {
                Text("Drag to rate")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(RatingTrack.accessibilityValue(rating))
        .accessibilityAdjustableAction { direction in
            let adjusted = RatingTrack.adjusted(rating, by: direction == .increment ? 1 : -1)
            commit(adjusted, method: .accessibility)
        }
    }

    // MARK: - Track

    private var track: some View {
        GeometryReader { geometry in
            // The glyphs occupy the inner width; the 24pt of slop at each end is part of the hit
            // area, not of the track (§2.1). So the leading slop maps entirely to 0.5 and the
            // trailing slop to 5.0 — the extremes are reachable without hitting a glyph exactly.
            let trackWidth = max(1, geometry.size.width - 2 * Theme.Size.ratingHitSlop)
            StarRow(score: rating?.value, starSize: starSize, spread: true)
                .symbolEffect(.wiggle, options: .nonRepeating, value: wiggleTrigger)
                // The settle. A brief compression into a spring back to rest — 0.28s in total, and
                // it starts the instant the finger leaves, so it reads as the row *landing* on the
                // value rather than as an animation played at you. Reduce Motion never triggers it.
                .keyframeAnimator(initialValue: 1.0, trigger: settleTrigger) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(0.96, duration: 0.06)
                    SpringKeyframe(1.0, duration: 0.22, spring: .snappy)
                }
                .frame(width: trackWidth)
                .padding(.horizontal, Theme.Size.ratingHitSlop)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: trackWidth))
        }
        .frame(height: Theme.Size.ratingTrackHeight)
    }

    /// §6 moment #4: a score that changes *in place* rolls rather than swaps — but only when no
    /// finger is on the track. §2.3 outranks §6: during a scrub the number must not lag the thumb by
    /// so much as a frame, so the transition is switched off for the duration of the touch.
    private var readout: some View {
        Text(ScoreFormat.halfStep(rating?.value))
            .font(Theme.Text.scoreNumeral)
            .foregroundStyle(rating == nil ? Theme.Color.textTertiary : Theme.Color.textPrimary)
            .contentTransition(.numericText())
            .animation(isScrubbing || reduceMotion ? nil : .snappy(duration: 0.2), value: rating)
    }

    private var isScrubbing: Bool { scrubStartValue != nil }

    private var starSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? Theme.Size.star * 2.2 : Theme.Size.star * 2
    }

    private func scrubGesture(width: CGFloat) -> RatingScrubGesture {
        RatingScrubGesture(
            onBegan: {
                scrubStartValue = .some(rating)
                LogHaptics.prepareSelection()
            },
            onChanged: { positionX in
                let next = RatingTrack.rating(atX: trackX(positionX), trackWidth: width)
                guard next != rating else { return }
                rating = next
                // A half-step crossing is the only thing worth a tick — one per zone, not per frame.
                LogHaptics.selectionChanged()
            },
            onEnded: { positionX, method in
                guard let start = scrubStartValue else { return }
                scrubStartValue = nil
                // Moment #1, on every lift — including the one that didn't change the value. The
                // settle is feedback that the gesture ENDED, not that the score moved.
                if !reduceMotion { settleTrigger += 1 }
                let final = RatingTrack.rating(atX: trackX(positionX), trackWidth: width)
                guard final != start else {
                    rating = final
                    return
                }
                // §2.3: one soft impact on release, and only if the value actually moved.
                LogHaptics.ratingSettled()
                commit(final, method: method)
            },
            onCancelled: {
                // A system interruption mid-scrub is not a reason to lose the score under the
                // thumb — but it must not be recorded twice either, so it settles like a release.
                guard let start = scrubStartValue else { return }
                scrubStartValue = nil
                guard let current = rating, current != start else { return }
                commit(current, method: .drag)
            }
        )
    }

    /// The gesture is measured on the full hit area; the mapping expects a position on the *track*.
    private func trackX(_ location: CGFloat) -> Double {
        Double(location - Theme.Size.ratingHitSlop)
    }

    private func commit(_ value: Rating, method: LogRatingMethod) {
        rating = value
        hasRatedOnce = true
        onChange(value, method)
    }
}

#Preview("Rating control") {
    @Previewable @State var unset: Rating?
    @Previewable @State var set: Rating? = Rating(rounding: 4.5)

    VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
        RatingControl(rating: $unset)
        RatingControl(rating: $set)
    }
    .padding(Theme.Spacing.gutter)
}

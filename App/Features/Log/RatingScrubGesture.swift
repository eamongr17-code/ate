import AteKit
import SwiftUI
import UIKit

/// The rating scrub's *recognizer* — the device-only half of custom surface #1 (§2).
///
/// **Why this is not a `DragGesture`.** The track lives on a card inside a scrolling `List`, and a
/// `DragGesture(minimumDistance: 0)` in that position loses every argument it has with the scroll
/// view. It fires on touch-down, so a thumb that only meant to scroll past the card repaints the
/// score before it moves a millimetre; then the list's pan recognises, SwiftUI cancels the drag, and
/// `onEnded` never runs — so the value is left mid-scrub with no settle haptic, no `log_rating_set`
/// and the "Drag to rate" hint still on screen. That is the "super glitchy" scrub, and none of it
/// reproduces with a mouse in the simulator, where a click's translation is exactly zero and a drag
/// is perfectly straight.
///
/// This recognizer takes the same position a `UISlider` takes in a table view, but with an axis
/// lock, which is what makes the card scrollable *through* the track:
///
///  * **Touch down changes nothing.** No value is written until the gesture is claimed.
///  * **The axis is called at 4 pt** (``RatingTrack/intent(dx:dy:slop:)``), before `UIScrollView`'s
///    own ~10 pt pan slop. Horizontal → we `.began`, which fails the list's pan for the rest of the
///    touch, so the scrub can never be interrupted halfway. Vertical → we `.failed` immediately and
///    the list scrolls as if the track weren't there.
///  * **A lift with no movement is a tap** — `.possible → .ended`, the discrete transition — which
///    keeps §2.3's "a tap and a scrub are the same code path" true while reporting an honest
///    `log_rating_set(method:)`. The old `translation.width == 0` test called every real-thumb tap a
///    drag, because a thumb never lifts on the pixel it landed on.
///  * **Every touch ends in exactly one terminal callback**, so there is no stuck-scrubbing state.
final class RatingScrubRecognizer: UIGestureRecognizer {
    /// True once the touch was claimed as a horizontal scrub. False on a tap.
    private(set) var didScrub = false

    private var primaryTouch: UITouch?
    private var origin: CGPoint = .zero

    override func reset() {
        super.reset()
        didScrub = false
        primaryTouch = nil
        origin = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // A second finger on the track is noise, not a two-finger gesture — the first one owns it.
        for touch in touches where touch !== primaryTouch {
            if primaryTouch == nil {
                primaryTouch = touch
                origin = touch.location(in: view)
            } else {
                ignore(touch, for: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        let point = touch.location(in: view)

        switch state {
        case .possible:
            let intent = RatingTrack.intent(
                dx: Double(point.x - origin.x),
                dy: Double(point.y - origin.y)
            )
            switch intent {
            case .undecided:
                break
            case .scrub:
                didScrub = true
                state = .began
            case .scroll:
                // Hand the touch back to the list, untouched and un-rated.
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            // Lifted without ever moving past the slop: a tap.
            state = .ended
        case .began, .changed:
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }
}

/// The SwiftUI seam for ``RatingScrubRecognizer``.
///
/// `UIGestureRecognizerRepresentable` (iOS 18+, free at our iOS 26 floor) exists precisely so a
/// custom control can join UIKit's gesture arbitration instead of guessing at SwiftUI's. All this
/// type does is translate recognizer states into the four things the control cares about; the x →
/// score arithmetic stays in ``RatingTrack``, where it is unit-tested.
struct RatingScrubGesture: UIGestureRecognizerRepresentable {
    /// The scrub (or tap) has been claimed — the moment to snapshot the starting value.
    var onBegan: () -> Void
    /// The finger is at `x` points from the leading edge of the hit area.
    var onChanged: (CGFloat) -> Void
    /// Settled at `x`, by `method`.
    var onEnded: (CGFloat, LogRatingMethod) -> Void
    /// The system took the touch away (a call, a notification pull-down).
    var onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> RatingScrubRecognizer {
        RatingScrubRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: RatingScrubRecognizer, context: Context) {
        let positionX = context.converter.localLocation.x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(positionX)
        case .changed:
            onChanged(positionX)
        case .ended:
            if recognizer.didScrub {
                onEnded(positionX, .drag)
            } else {
                // A tap never sent `.began`, so the control still needs its snapshot first.
                onBegan()
                onEnded(positionX, .tap)
            }
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

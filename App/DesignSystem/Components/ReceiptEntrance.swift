import SwiftUI

/// Where an entering receipt is. ``settled`` is the receipt at rest: what every other card, and
/// every export, draws.
struct ReceiptPose: Equatable {
    /// How much of the paper is out of the slot: 0 is all inside, 1 is all out.
    var fed: Double = 1
    /// The paper's turn, the artboard's −3° at rest.
    var tilt: Double = ReceiptPose.restingTilt
    /// The photos behind the paper: 0 is not there yet, 1 is landed.
    var photos: Double = 1

    /// `transform:rotate(-3deg)`, the paper at rest.
    static let restingTilt: Double = -3

    static let settled = ReceiptPose()
    /// The first frame of the entrance: inside the slot, straight, no photos yet.
    static let start = ReceiptPose(fed: 0, tilt: 0, photos: 0)
}

/// **How a whole receipt enters the Summary: the printer feed** (round 5, Eamon's pick). The
/// receipt only ever enters once its shape is final (the sorter has answered), so the entrance is
/// the one piece of theatre left. The paper rises straight out of a slot at its own foot, the top
/// first, at a printer's pace; then it is torn off (it tips to its −3°) and the photos land behind
/// it. Every step is gated on Reduce Motion by its caller: with it on, the receipt is simply there.
enum ReceiptEntrance {
    /// The coral ground's own fade gets a head start, so the paper enters a finished stage.
    static let groundLead: Duration = .milliseconds(180)
    /// The paper's rise, at a printer's steady pace easing out at the end of the feed.
    static let feedRise = Animation.timingCurve(0.3, 0.05, 0.3, 1, duration: 0.95)
    static let feedRiseTime: Duration = .milliseconds(950)
    /// The tear: the paper tips from straight to its −3°.
    static let tear = Animation.spring(duration: 0.45, bounce: 0.38)
    static let tearLead: Duration = .milliseconds(90)
    /// The photos landing behind the paper.
    static let photosLand = Animation.spring(duration: 0.5, bounce: 0.28)
    /// How far a photo drops from as it lands.
    static let photoDrop: CGFloat = 1.12
}

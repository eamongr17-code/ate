import SwiftUI

/// **How a whole receipt enters the Summary** (round 5). The receipt only ever enters once its shape
/// is final — the sorter has answered — so the entrance is the one piece of theatre left, and it
/// hides nothing but itself. Two answers, on the device, until Eamon picks:
/// `-ate-r5-compose A|B` (Debug and Beta; A without the argument).
enum ReceiptEntranceStyle: String {
    /// **A — the printer feed.** The paper rises straight out of a slot at its own foot, the place
    /// first, at a printer's pace; then it is torn off — it tips to its −3° — and the photos land.
    case feed = "A"
    /// **B — the fold.** The receipt arrives folded in half, its upper half first; the lower half
    /// swings down flat, and the photos land.
    case fold = "B"

    static var current: ReceiptEntranceStyle {
        #if DEBUG || BETA
        UserDefaults.standard.string(forKey: "ate-r5-compose").flatMap(Self.init(rawValue:)) ?? .feed
        #else
        .feed
        #endif
    }
}

/// Where an entering receipt is. ``settled`` is the receipt at rest — what every other card, and
/// every export, draws.
struct ReceiptPose: Equatable {
    /// How much of the paper is out of the slot (A): 0 is all inside, 1 is all out.
    var fed: Double = 1
    /// How far the lower half is still folded back, in degrees (B): 90 is edge-on, 0 is flat.
    var fold: Double = 0
    /// The paper's turn — the artboard's −3° at rest.
    var tilt: Double = ReceiptPose.restingTilt
    /// The photos behind the paper: 0 is not there yet, 1 is landed.
    var photos: Double = 1
    /// The whole card on its way in (B): 0 is above and clear, 1 is arrived.
    var arrived: Double = 1

    /// `transform:rotate(-3deg)` — the paper at rest.
    static let restingTilt: Double = -3

    static let settled = ReceiptPose()

    /// The first frame of an entrance.
    static func start(_ style: ReceiptEntranceStyle) -> ReceiptPose {
        switch style {
        case .feed: ReceiptPose(fed: 0, tilt: 0, photos: 0)
        case .fold: ReceiptPose(fold: 90, photos: 0, arrived: 0)
        }
    }
}

/// The choreography, step by step. Every step is gated on Reduce Motion by its caller: with it on,
/// the receipt is simply there.
enum ReceiptEntrance {
    /// The coral ground's own fade gets a head start, so the paper enters a finished stage.
    static let groundLead: Duration = .milliseconds(180)

    // A — feed
    /// The paper's rise, at a printer's steady pace easing out at the end of the feed.
    static let feedRise = Animation.timingCurve(0.3, 0.05, 0.3, 1, duration: 0.95)
    static let feedRiseTime: Duration = .milliseconds(950)
    /// The tear: the paper tips from straight to its −3°.
    static let tear = Animation.spring(duration: 0.45, bounce: 0.38)
    static let tearLead: Duration = .milliseconds(90)

    // B — fold
    static let arrive = Animation.easeOut(duration: 0.35)
    static let arriveLead: Duration = .milliseconds(200)
    static let unfold = Animation.spring(duration: 0.62, bounce: 0.22)
    static let unfoldTime: Duration = .milliseconds(420)

    /// The photos landing behind the paper, both variants.
    static let photosLand = Animation.spring(duration: 0.5, bounce: 0.28)
    /// How far a photo drops from as it lands.
    static let photoDrop: CGFloat = 1.12
}

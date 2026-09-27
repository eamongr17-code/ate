import Foundation

/// **Whether a tab root's floating header is up**, as a function of the scroll (round 4).
///
/// The header in the page scrolls away on the way down; a copy floats back over the list on the way
/// up. This is the decision, kept out of the view so it can be tested: up after a scroll up of more
/// than a few points, down after a scroll down of the same, and always down at the top — where the
/// header in the page is the one on screen. Only a person's own scrolling counts, and not the bounce
/// past the bottom.
public struct AteHeaderTrack: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        /// 0 at rest at the top; negative while pulled down.
        public var offset: CGFloat
        /// The furthest the content can scroll.
        public var maxOffset: CGFloat

        public init(offset: CGFloat, maxOffset: CGFloat) {
            self.offset = offset
            self.maxOffset = maxOffset
        }
    }

    public private(set) var offset: CGFloat = 0
    /// Back over the list: raised by a scroll up, lowered by a scroll down or by reaching the top.
    public private(set) var isFloating = false
    /// Whether the glass tab bar is (as far as the app can tell) at full size: the system minimises
    /// it on a scroll down, and the shell holds it open whenever the header floats. Public API gives
    /// no reading of the bar's own state, so this is the app's model of it — what draws its shadow.
    public private(set) var isBarExpanded = true
    /// Movement in the current direction, so a jitter of a point or two does not flip the header.
    private var travel: CGFloat = 0

    /// How far the finger has to go the other way before the header changes its mind.
    public static let hysteresis: CGFloat = 6
    /// A scroll to the top can land a fraction short of it.
    public static let topSlack: CGFloat = 1

    public init() {}

    public mutating func update(_ sample: Sample, isPersonScrolling: Bool = true) {
        let previous = offset
        offset = sample.offset
        // At the top, or pulled past it: the header in the page is on screen.
        guard sample.offset > Self.topSlack else {
            isFloating = false
            isBarExpanded = true
            travel = 0
            return
        }
        // Past the bottom (the bounce) is not the reader choosing a direction, and neither is the
        // system moving the content.
        let end = sample.maxOffset - 0.5
        // …but the system may minimise the bar on a drag into the bounce, and nothing says whether it
        // did: the model errs to minimised, so a full-size shadow is never left under a small bar.
        // Not while the header floats — the shell holds the bar open then, and it cannot minimise.
        if isPersonScrolling, sample.offset >= end, isFloating == false { isBarExpanded = false }
        guard isPersonScrolling, sample.offset < end, previous > 0, previous < end else { return }
        let delta = sample.offset - previous
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel > Self.hysteresis {
            isFloating = false
            isBarExpanded = false
        }
        if travel < -Self.hysteresis {
            isFloating = true
            isBarExpanded = true
        }
    }

    /// The tab this tracks became the current one. A tab is only ever chosen on the full bar, so
    /// the bar is at full size now whatever this tab last saw — and the next scroll down, which
    /// minimises it, has to read as a change.
    public mutating func tabBecameCurrent() {
        expandBar()
    }

    /// The minimised bar was tapped open (or a tab chosen on it): it is at full size now, and the
    /// next scroll down — which minimises it again — starts from nothing.
    public mutating func expandBar() {
        isBarExpanded = true
        travel = 0
    }
}

/// **A bottom sheet's height, fitted to what it holds** (round 4: no big empty areas).
///
/// The sheet measures its head (title and search field), its content and its foot (the one pill),
/// and this adds them up with the sheet's gaps. It only ever grows while the sheet is up, so a search
/// whose results thin out as you type does not pull the sheet down under the thumb.
public struct AteSheetFit: Equatable, Sendable {
    public var head: CGFloat = 0 { didSet { grow() } }
    public var body: CGFloat = 0 { didSet { grow() } }
    public var foot: CGFloat = 0 { didSet { grow() } }
    public var hasFoot = false { didSet { grow() } }
    /// The tallest fit so far; 0 until the head has been measured.
    public private(set) var tallest: CGFloat = 0

    /// The gap between head, content and foot.
    public let gap: CGFloat
    /// The clearance under the content when there is no pill to carry it.
    public let bottom: CGFloat

    public init(gap: CGFloat, bottom: CGFloat) {
        self.gap = gap
        self.bottom = bottom
    }

    public var height: CGFloat {
        (head + body + (hasFoot ? foot : bottom) + gap * (hasFoot ? 2 : 1)).rounded(.up)
    }

    private mutating func grow() {
        guard head > 0, hasFoot == false || foot > 0 else { return }
        tallest = max(tallest, height)
    }
}

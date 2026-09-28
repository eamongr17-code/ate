import CoreGraphics

/// **Where everything in the tab bar sits**, full and minimised (round 6) — kept out of the view so
/// the geometry can be tested.
///
/// All points are in the bar's own space: its top-leading corner is the origin, it is `width` wide
/// and ``height`` tall. Read off iOS 26's bar on a 402pt phone (build 80): a 62 capsule, the `+` a
/// 62 disc 8 beside it; four slots inside 23/3 of padding; the current tab's pill 76×54, 4 in;
/// minimised, a 48 disc 7 in and the `+` 48 on the same centre.
///
/// A tab is drawn as a *face* — its icon over its label, one slot wide and the bar tall — so its icon
/// is not at the face's centre. Round 6's bug was exactly that: minimised, the face was centred on
/// the disc, which left the icon 7 above it. ``faceCentre(iconOn:)`` is how a face is placed so its
/// icon lands where it should, full or minimised, and on every frame of the morph between.
public struct TabBarGeometry: Equatable, Sendable {
    public static let height: CGFloat = 62
    public static let gap: CGFloat = 8
    public static let capsulePadding: CGFloat = 23.0 / 3.0
    public static let minimised: CGFloat = 48
    public static let pillWidth: CGFloat = 76
    public static let pillInset: CGFloat = 4
    /// The icon's box inside a face: 24 square, 12 from the face's top.
    public static let icon: CGFloat = 24
    public static let iconTop: CGFloat = 12

    public let width: CGFloat
    public let tabCount: Int

    public init(width: CGFloat, tabCount: Int) {
        self.width = width
        self.tabCount = max(tabCount, 1)
    }

    // MARK: - The pieces

    public var capsuleWidth: CGFloat { width - Self.gap - Self.height }
    public var slot: CGFloat { (capsuleWidth - 2 * Self.capsulePadding) / CGFloat(tabCount) }
    /// How far the minimised disc (and the minimised `+`) sits in from the full size's edge.
    public var discInset: CGFloat { (Self.height - Self.minimised) / 2 }

    /// The glass behind the tabs: the capsule when full, the disc when minimised.
    public func capsule(isExpanded: Bool) -> CGRect {
        isExpanded
            ? CGRect(x: 0, y: 0, width: capsuleWidth, height: Self.height)
            : CGRect(x: discInset, y: discInset, width: Self.minimised, height: Self.minimised)
    }

    /// The `+`: the same centre full or minimised, only its size changes.
    public func plus(isExpanded: Bool) -> CGRect {
        let side = isExpanded ? Self.height : Self.minimised
        let centre = CGPoint(x: width - Self.height / 2, y: Self.height / 2)
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    /// The centre of a tab's slot in the full bar — where its control is, and where its face sits.
    public func slotCentre(_ index: Int) -> CGPoint {
        CGPoint(x: Self.capsulePadding + slot * (CGFloat(index) + 0.5), y: Self.height / 2)
    }

    /// The minimised disc's centre.
    public var discCentre: CGPoint {
        CGPoint(x: discInset + Self.minimised / 2, y: Self.height / 2)
    }

    /// The pill's leading edge under the tab at `index`: centred on its slot, kept 4 inside the
    /// capsule at either end.
    public func pillMinX(_ index: Int) -> CGFloat {
        let centred = slotCentre(index).x - Self.pillWidth / 2
        return min(max(centred, Self.pillInset), capsuleWidth - Self.pillInset - Self.pillWidth)
    }

    // MARK: - Faces

    /// Where a face's icon is, for a face centred on `faceCentre`.
    public static func iconCentre(faceCentre: CGPoint) -> CGPoint {
        CGPoint(x: faceCentre.x, y: faceCentre.y - height / 2 + iconTop + icon / 2)
    }

    /// Where to centre a face so its icon sits on `point`.
    public static func faceCentre(iconOn point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y + height / 2 - iconTop - icon / 2)
    }

    /// A tab's face, full: in its slot.
    public func expandedFace(_ index: Int) -> CGPoint { slotCentre(index) }

    /// Every tab's face, minimised: gathered so the icon is dead centre in the disc (the current
    /// one shows; the rest fold into it).
    public var minimisedFace: CGPoint { Self.faceCentre(iconOn: discCentre) }
}

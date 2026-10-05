import SwiftUI

/// **Every icon in the app, from Lucide — the one icon set Ate uses.**
///
/// Eamon picked Lucide (ISC, `lucide-static` 1.48.0) in round 5 as the single set, used exclusively
/// from here on; the licence is in `THIRD_PARTY_NOTICES`. Each case carries the Lucide glyph's own
/// geometry — 24-unit viewBox, round caps and joins — copied out of the package's SVG unedited, so
/// the icons ship as vectors with no runtime dependency. The name beside each case is the Lucide
/// icon it is.
///
/// No SF Symbol appears in `App/` (SwiftLint's `no_sf_symbols` holds that line); a new icon is a new
/// case here, taken from Lucide.
enum AteIcon: String, CaseIterable {
    // Tabs
    case journal, feed, search, you, compose

    // The atoms
    case star, starFilled, place, photoStack

    // Actions
    case share, edit, save, saved, camera, library, close, back, check, chevron, settings
    /// The one "…" that carries everything you can do about a person or an entry, and the two
    /// answers underneath it.
    case more, flag, block
    /// The composer's Diet key.
    case diet
    /// The journal's filter and sort.
    case filter
    /// A dish, where a picture of one is missing.
    case dish
    /// Clear a field or dismiss a cover — Lucide's circle-x, filled, with the cross knocked out.
    case clear
    /// The Feed's Near me — Lucide's navigation.
    case navigation
    /// The journal's calendar (round 7) — Lucide's calendar.
    case calendar
    /// A filter chip's "opens a sheet" mark (round 7) — Lucide's chevron-down.
    case chevronDown
    /// **The one filter glyph** of the rebuild (Journal and Search mockups) — Lucide's list-filter,
    /// three shortening lines. The old screens keep ``filter`` (sliders) until their flow is rebuilt.
    case listFilter
    /// The Feed's cravings (Eamon's fix for an unclear icon) — Lucide's heart.
    case heart
    /// A category — the What you follow row at the end of the Feed (4 Oct) — Lucide's tag.
    case tag
    /// A menu's current value, in the filter sheet — Lucide's chevrons-up-down. **A control mark
    /// only** (Menu rows): never a label's icon.
    case chevronsUpDown
    /// The filter sheet's Sort label (build 87, note 3) — Lucide's arrow-down-wide-narrow. A label
    /// icon is never a glyph the app uses as a control affordance.
    case arrowDownWideNarrow
    /// The composer's With key, before anyone is on it ("Ate with") — Lucide's user-plus.
    case userPlus
    /// "Remove me" on an entry you were tagged on — Lucide's user-minus.
    case userMinus
    /// You's notifications ("Ate with") — Lucide's bell.
    case bell

    /// What is stroked, in draw order.
    var strokes: [Path] {
        switch self {
        case .journal: // receipt-text
            [Self.path("""
M4 3a1 1 0 0 1 1-1 1.3 1.3 0 0 1 .7.2l.933.6a1.3 1.3 0 0 0 1.4 0l.934-.6a1.3 1.3 0 0 1 1.4 0l.933.6a1.3 \
1.3 0 0 0 1.4 0l.933-.6a1.3 1.3 0 0 1 1.4 0l.934.6a1.3 1.3 0 0 0 1.4 0l.933-.6A1.3 1.3 0 0 1 19 2a1 1 0 0 \
1 1 1v18a1 1 0 0 1-1 1 1.3 1.3 0 0 1-.7-.2l-.933-.6a1.3 1.3 0 0 0-1.4 0l-.934.6a1.3 1.3 0 0 1-1.4 0l-.93\
3-.6a1.3 1.3 0 0 0-1.4 0l-.933.6a1.3 1.3 0 0 1-1.4 0l-.934-.6a1.3 1.3 0 0 0-1.4 0l-.933.6a1.3 1.3 0 0 1-.\
7.2 1 1 0 0 1-1-1z
"""), Self.path("M13 16H8"), Self.path("M14 8H8"), Self.path("M16 12H8")]
        case .feed: // utensils-crossed (round 6, Eamon: two people read too close to You)
            [Self.path("m16 2-2.3 2.3a3 3 0 0 0 0 4.2l1.8 1.8a3 3 0 0 0 4.2 0L22 8"),
             Self.path("M15 15 3.3 3.3a4.2 4.2 0 0 0 0 6l7.3 7.3c.7.7 2 .7 2.8 0L15 15Zm0 0 7 7"),
             Self.path("m2.1 21.8 6.4-6.3"), Self.path("m19 5-7 7")]
        case .search: // search
            [Self.path("m21 21-4.34-4.34"), AteVector.circle(11, 11, 8)]
        case .you: // user
            [Self.path("M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"), AteVector.circle(12, 7, 4)]
        case .compose: // plus
            [Self.path("M5 12h14"), Self.path("M12 5v14")]
        case .star, .starFilled: // star
            [Self.starPath]
        case .place: // map-pin
            [Self.path("""
M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0
"""), AteVector.circle(12, 10, 3)]
        case .photoStack: // images
            [Self.path("m22 11-1.296-1.296a2.4 2.4 0 0 0-3.408 0L11 16"),
             Self.path("M4 8a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2"),
             Self.imagesDot, AteVector.rectangle(8, 2, 14, 14, 2)]
        case .share: // share
            [Self.path("M12 2v13"), Self.path("m16 6-4-4-4 4"),
             Self.path("M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8")]
        case .edit: // pencil
            [Self.path("""
M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1\
.32a2 2 0 0 0 .83-.497z
"""), Self.path("m15 5 4 4")]
        case .save, .saved: // bookmark
            [Self.bookmarkPath]
        case .camera: // camera
            [Self.path("""
M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V\
9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z
"""), AteVector.circle(12, 13, 3)]
        case .library: // image
            [AteVector.rectangle(3, 3, 18, 18, 2), AteVector.circle(9, 9, 2),
             Self.path("m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21")]
        case .close: // x
            [Self.path("M18 6 6 18"), Self.path("m6 6 12 12")]
        case .back: // chevron-left
            [Self.path("m15 18-6-6 6-6")]
        case .check: // check
            [Self.path("M20 6 9 17l-5-5")]
        case .chevron: // chevron-right
            [Self.path("m9 18 6-6-6-6")]
        case .settings: // settings
            [Self.gearPath, AteVector.circle(12, 12, 3)]
        case .more: // ellipsis
            [AteVector.circle(12, 12, 1), AteVector.circle(19, 12, 1), AteVector.circle(5, 12, 1)]
        case .flag: // flag
            // Lucide writes one segment as a quadratic, `q2 0 3.067-.8`; it is carried here as the
            // identical cubic (`c1.333 0 2.356-.267 3.067-.8`), the only form `AteVector` reads.
            [Self.path("""
M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2c1.333 0 2.356-.267 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 \
0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528
""")]
        case .block: // ban
            [AteVector.circle(12, 12, 10), Self.path("M4.929 4.929 19.07 19.071")]
        case .diet: // leaf
            [Self.path("""
M11 20a10 10 0 0010-10 25.9 25.9 0 00-1.04-7.281 1 1 0 00-1.755-.325C15.833 5.5 13 5.5 9.8 6.1A7 7 0 0011 20
"""), Self.path("M2 21a5 5 0 012.911-4.544C7.613 15.212 8.351 15.24 11 13")]
        case .filter: // sliders-horizontal
            [Self.path("M10 5H3"), Self.path("M12 19H3"), Self.path("M14 3v4"), Self.path("M16 17v4"),
             Self.path("M21 12h-9"), Self.path("M21 19h-5"), Self.path("M21 5h-7"), Self.path("M8 10v4"),
             Self.path("M8 12H3")]
        case .dish: // utensils
            [Self.path("M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2"), Self.path("M7 2v20"),
             Self.path("M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7")]
        case .clear: // circle-x
            [AteVector.circle(12, 12, 10)]
        case .navigation: // navigation
            [Self.path("M3 11L22 2L13 21L11 13Z")]
        case .calendar: // calendar
            [Self.path("M8 2v4"), Self.path("M16 2v4"), AteVector.rectangle(3, 4, 18, 18, 2), Self.path("M3 10h18")]
        case .chevronDown: // chevron-down
            [Self.path("m6 9 6 6 6-6")]
        case .chevronsUpDown: // chevrons-up-down
            [Self.path("m7 15 5 5 5-5"), Self.path("m7 9 5-5 5 5")]
        case .arrowDownWideNarrow: // arrow-down-wide-narrow
            [Self.path("m3 16 4 4 4-4"), Self.path("M7 20V4"), Self.path("M11 4h10"),
             Self.path("M11 8h7"), Self.path("M11 12h4")]
        case .tag: // tag
            [Self.path("""
M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 \
0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z
"""), Self.tagDot]
        case .userPlus: // user-plus
            [Self.path("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"), AteVector.circle(9, 7, 4),
             Self.path("M19 8v6"), Self.path("M22 11h-6")]
        case .userMinus: // user-minus
            [Self.path("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"), AteVector.circle(9, 7, 4),
             Self.path("M22 11h-6")]
        case .bell: // bell
            [Self.path("M10.268 21a2 2 0 0 0 3.464 0"),
             Self.path("M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8"
                 + "c0 4.499-1.411 5.956-2.738 7.326")]
        case .listFilter: // list-filter
            [Self.path("M2 5h20"), Self.path("M6 12h12"), Self.path("M9 19h6")]
        case .heart: // heart
            [Self.path("""
M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 \
2.3 1.5 4.05 3 5.5l7 7Z
""")]
        }
    }

    /// What is filled. Lucide draws no filled glyphs, so a filled state is the outline's own path,
    /// filled — and still stroked, so the filled and empty states have the same silhouette.
    var fills: [Path] {
        switch self {
        case .starFilled: [Self.starPath]
        case .saved: [Self.bookmarkPath]
        case .clear: [AteVector.circle(12, 12, 10)]
        // `images` fills its own sun, in the SVG.
        case .photoStack: [Self.imagesDot]
        case .tag: [Self.tagDot]
        default: []
        }
    }

    /// What is knocked out of the fill, at the stroke's width — the cross in ``clear``.
    var cutouts: [Path] {
        switch self {
        case .clear: [Self.path("m15 9-6 6"), Self.path("m9 9 6 6")]
        default: []
        }
    }

    private static let starPath = path("""
M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3\
.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.97\
3 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.\
906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z
""")
    private static let bookmarkPath = path("""
M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 \
2 0 0 1 2-2z
""")
    private static let gearPath = path("""
M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 \
0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3\
.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.\
319-1.915
""")
    private static let imagesDot = AteVector.circle(13, 7, 1)
    /// `tag`'s hole: `<circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>`.
    private static let tagDot = AteVector.circle(7.5, 7.5, 0.5)

    private static func path(_ data: String) -> Path { AteVector.path(data) }
}

extension AteIcon {
    /// An icon at a size, in the current foreground colour. The stroke is in the 24-unit box, so it
    /// thins and thickens with the icon exactly as the SVG does.
    func view(size: CGFloat, lineWidth: CGFloat = AteIconShape.strokeWidth) -> some View {
        AteIconView(icon: self, size: size, lineWidth: lineWidth)
    }
}

/// One icon's geometry, scaled into whatever box it is given.
struct AteIconShape: Shape {
    /// The line weight: 1.8 in the 24-unit box — Lucide's own 2, at ``opticalScale``.
    static let strokeWidth: CGFloat = 1.8
    /// Lucide draws to a 2-unit margin, the old hand-drawn set to about 3.5, so at the same point size
    /// Lucide's glyphs read a size larger. Drawn at 90% about the centre they keep the ink box — and,
    /// with Lucide's 2 stroke, the 1.8 weight — every call site was laid out against.
    static let opticalScale: CGFloat = 0.9

    let paths: [Path]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / AteVector.viewBox * Self.opticalScale
        let inset = side * (1 - Self.opticalScale) / 2
        let transform = CGAffineTransform(translationX: rect.minX + inset, y: rect.minY + inset)
            .scaledBy(x: scale, y: scale)
        var combined = Path()
        for path in paths {
            combined.addPath(path, transform: transform)
        }
        return combined
    }
}

/// The drawn icon: fills, then strokes, then any knock-out, all in the inherited foreground colour.
struct AteIconView: View {
    let icon: AteIcon
    let size: CGFloat
    var lineWidth: CGFloat = AteIconShape.strokeWidth

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth * size / AteVector.viewBox, lineCap: .round, lineJoin: .round)
        ZStack {
            let fills = icon.fills
            if fills.isEmpty == false {
                AteIconShape(paths: fills).fill()
            }
            let strokes = icon.strokes
            if strokes.isEmpty == false {
                AteIconShape(paths: strokes).stroke(style: style)
            }
            let cutouts = icon.cutouts
            if cutouts.isEmpty == false {
                AteIconShape(paths: cutouts).stroke(style: style).blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A 44pt tappable icon — the app's standard toolbar/bar-button unit (design: 44pt minimum targets).
struct AteIconButton: View {
    let icon: AteIcon
    let label: String
    var size: CGFloat = 22
    var tint: Color?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            icon.view(size: size)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .foregroundStyle(tint ?? palette.fg)
        .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Icons") {
    let columns = [GridItem(.adaptive(minimum: 56))]
    return ScrollView {
        LazyVGrid(columns: columns, spacing: AteMetrics.loose) {
            ForEach(AteIcon.allCases, id: \.self) { icon in
                icon.view(size: 28)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(AteMetrics.gutter)
    }
    .ateGround()
}
#endif

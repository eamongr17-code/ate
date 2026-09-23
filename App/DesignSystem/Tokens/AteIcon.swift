import SwiftUI

/// **Every icon in the app, drawn the way `design/v1` draws it.**
///
/// Design rule 1 is "icons before labels", which makes the icon set load-bearing — and the artboards
/// draw their own. So each case below carries the artboard's own geometry (24-unit viewBox, 1.8
/// stroke, round caps and joins) rather than the nearest SF Symbol: a `mappin` is not the prototype's
/// pin, `text.page` is not its receipt, and at 22pt the difference is the whole character of the
/// chrome. The strings are copied out of the markup unedited.
///
/// No SF Symbol appears anywhere the design draws its own icon.
enum AteIcon: String, CaseIterable {
    // Tabs
    case journal, feed, search, you, compose

    // The atoms
    case star, starFilled, place, photoStack

    // Visibility
    case publicEntry, privateEntry

    // Actions
    case share, edit, save, saved, camera, library, voice, close, back, check, chevron, settings
    /// The one "…" that carries everything you can do about a person or an entry, and the two
    /// answers underneath it.
    case more, flag, block

    /// What is stroked, in draw order.
    var strokes: [Path] {
        switch self {
        case .journal:
            [Self.path("M6 3h12v18l-2-1.5-2 1.5-2-1.5-2 1.5-2-1.5L6 21z"), Self.path("M9 8h6M9 12h6")]
        case .feed:
            [AteVector.circle(9, 9, 3.2),
             Self.path("M3 19c.8-3.4 3.2-4.8 6-4.8s5.2 1.4 6 4.8"),
             Self.path("M15.5 6.2a3.2 3.2 0 0 1 0 5.8M17.5 14.6c1.9.6 3.1 2 3.6 4.4")]
        case .search:
            [AteVector.circle(11, 11, 6.5), Self.path("M16 16l4.5 4.5")]
        case .you:
            [AteVector.circle(12, 8.5, 3.5), Self.path("M5 20c1-4 4-5.5 7-5.5s6 1.5 7 5.5")]
        case .compose:
            [Self.path("M12 5v14M5 12h14")]
        case .star:
            [Self.starPath]
        case .starFilled:
            []
        case .place:
            [Self.path("M12 21s6.5-6 6.5-11a6.5 6.5 0 0 0-13 0c0 5 6.5 11 6.5 11z"),
             AteVector.circle(12, 10, 2.3)]
        case .photoStack:
            [AteVector.rectangle(3.5, 7.5, 14, 12, 3), Self.path("M7 4.5h10.5a3 3 0 0 1 3 3V16")]
        case .publicEntry:
            [AteVector.circle(12, 12, 8.5),
             Self.path("M3.5 12h17M12 3.5c3 3 3 14 0 17M12 3.5c-3 3-3 14 0 17")]
        case .privateEntry:
            [AteVector.rectangle(5.5, 10.5, 13, 9.5, 2), Self.path("M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5")]
        case .share:
            [Self.path("M12 15V4M8 7.5l4-4 4 4M5 12v7.5h14V12")]
        case .edit:
            [Self.path("M4 20l1-4.5L16.5 4 20 7.5 8.5 19z")]
        case .save:
            [Self.bookmarkPath]
        case .saved:
            []
        case .camera:
            [Self.path("M4 8h3l1.5-2h7L17 8h3v11H4z"), AteVector.circle(12, 13, 3.5)]
        case .library:
            [AteVector.rectangle(3.5, 5, 17, 14, 2),
             Self.path("M4 16l4.5-4.5 4 4 3-3L20 17"),
             AteVector.circle(9, 9.5, 1.3)]
        case .voice:
            [AteVector.rectangle(9, 3, 6, 11, 3), Self.path("M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3")]
        case .close:
            [Self.path("M6 6l12 12M18 6L6 18")]
        case .back:
            [Self.path("M14.5 5l-7 7 7 7")]
        case .check:
            [Self.path("M5 12.5l4.5 4.5L19 7.5")]
        case .chevron:
            [Self.path("M9.5 5l7 7-7 7")]
        case .settings:
            [AteVector.circle(12, 12, 3), Self.gearPath]
        case .more:
            [AteVector.circle(6, 12, 1.2), AteVector.circle(12, 12, 1.2), AteVector.circle(18, 12, 1.2)]
        case .flag:
            [Self.path("M6 21V4M6 5h11l-2 3.5 2 3.5H6")]
        case .block:
            [AteVector.circle(12, 12, 8.5), Self.path("M6 6l12 12")]
        }
    }

    /// What is filled. Only the two icons the design ever fills.
    var fills: [Path] {
        switch self {
        case .starFilled: [Self.starPath]
        case .saved: [Self.bookmarkPath]
        default: []
        }
    }

    private static let starPath = path(
        "M12 2.8l2.85 5.9 6.45.85-4.7 4.5 1.2 6.4L12 17.3l-5.8 3.15 1.2-6.4-4.7-4.5 6.45-.85z"
    )
    private static let bookmarkPath = path("M7 4h10a1 1 0 0 1 1 1v15l-6-4-6 4V5a1 1 0 0 1 1-1z")
    private static let gearPath = path("""
M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 \
0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 \
1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 \
1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l\
-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3\
a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 \
2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 \
2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z
""")

    private static func path(_ data: String) -> Path { AteVector.path(data) }
}

extension AteIcon {
    /// An icon at a size, in the current foreground colour. The stroke is 1.8 in the design's own
    /// 24-unit space, so it thins and thickens with the icon exactly as the SVG does.
    func view(size: CGFloat, lineWidth: CGFloat = AteIconShape.strokeWidth) -> some View {
        AteIconView(icon: self, size: size, lineWidth: lineWidth)
    }
}

/// One icon's geometry, scaled into whatever box it is given.
struct AteIconShape: Shape {
    /// The artboards' stroke: 1.8 in a 24-unit viewBox.
    static let strokeWidth: CGFloat = 1.8

    let paths: [Path]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / AteVector.viewBox
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
        var combined = Path()
        for path in paths {
            combined.addPath(path, transform: transform)
        }
        return combined
    }
}

/// The drawn icon: fills first, then strokes, both in the inherited foreground colour.
struct AteIconView: View {
    let icon: AteIcon
    let size: CGFloat
    var lineWidth: CGFloat = AteIconShape.strokeWidth

    var body: some View {
        ZStack {
            let fills = icon.fills
            if fills.isEmpty == false {
                AteIconShape(paths: fills).fill()
            }
            let strokes = icon.strokes
            if strokes.isEmpty == false {
                AteIconShape(paths: strokes)
                    .stroke(style: StrokeStyle(
                        lineWidth: lineWidth * size / AteVector.viewBox,
                        lineCap: .round,
                        lineJoin: .round
                    ))
            }
        }
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

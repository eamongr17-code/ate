import SwiftUI

/// **The empty state** — one anatomy app-wide: a hand-drawn ink illustration, one line in Bricolage
/// 800 at 40 under it, and at most one ink pill 22 below that, centred between the header and the tab
/// bar. No second line, no helper copy. The line's own breaks are the design's and are honoured.
///
/// The drawing is Paper Trail (Eamon, 2026-10-06): receipts that haven't printed yet, in marker, ink
/// only. When the band is too short for it (a sheet, a landscape phone) the drawing steps aside and
/// the line and pill stand alone, exactly as they did before.
///
/// It fills the space it is given and centres itself in it; the screen gives it the band between its
/// header and the tab bar.
struct AteEmptyState: View {
    let line: String
    var art: AteEmptyArt?
    var pill: (title: String, action: () -> Void)?

    init(line: String, art: AteEmptyArt? = nil, pill: (title: String, action: () -> Void)? = nil) {
        self.line = line
        self.art = art
        self.pill = pill
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            if let art {
                stack(art: art)
            }
            stack(art: nil)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stack(art: AteEmptyArt?) -> some View {
        VStack(spacing: 0) {
            if let art {
                AteEmptyDrawing(art: art)
                    .padding(.bottom, AteEmptyStateMetrics.artGap)
            }
            AteTitle(text: line, style: .screenTitle)
            if let pill {
                AteInkPill(title: pill.title, size: .empty, action: pill.action)
                    .padding(.top, AteEmptyStateMetrics.gap)
            }
        }
    }
}

/// **Which drawing an empty state carries** — by what the emptiness *is*, never by screen, so the same
/// situation looks the same wherever it happens.
enum AteEmptyArt: String, CaseIterable, Sendable {
    /// Your record has nothing yet: a blank docket feeding out of the printer, a pencil beside it.
    case journal = "Journal"
    /// No lists: an empty order spike.
    case lists = "Lists"
    /// A list (or the picker) with nothing on it: a numbered docket, every line blank.
    case list = "List"
    /// Nothing kept: a blank docket with a bookmark.
    case saved = "Saved"
    /// Other people's writing, none yet: an empty ticket rail and a fly.
    case rail = "Rail"
    /// Nothing new, or nobody signed in: the receipt printer, asleep.
    case printer = "Printer"
    /// A search or filter that matched nothing: a docket under a lens pulling a face.
    case search = "Search"
    /// Couldn't reach Ate, or the thing is gone: a torn docket.
    case torn = "Torn"
}

/// The drawing itself: two template layers, the paper under the ink, so dark mode flips it whole —
/// ink becomes the light foreground and the paper becomes the plum slip.
struct AteEmptyDrawing: View {
    let art: AteEmptyArt

    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack {
            layer("Paper").foregroundStyle(AteColor.slip)
            layer("Ink").foregroundStyle(palette.fg)
        }
        .frame(width: AteEmptyStateMetrics.artHeight * AteEmptyStateMetrics.artAspect,
               height: AteEmptyStateMetrics.artHeight)
        .accessibilityHidden(true)
    }

    private func layer(_ name: String) -> some View {
        Image("Empty\(art.rawValue)\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }
}

enum AteEmptyStateMetrics {
    /// `gap:22px` between the line and its pill.
    static let gap: CGFloat = 22
    /// The drawing's height, and the air between it and the line.
    static let artHeight: CGFloat = 160
    static let artGap: CGFloat = 20
    /// The artwork's canvas (180 × 140).
    static let artAspect: CGFloat = 180.0 / 140.0
}

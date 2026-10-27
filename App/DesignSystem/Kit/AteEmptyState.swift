import SwiftUI
import UIKit

/// **The empty state** — one anatomy app-wide: a hand-drawn ink illustration, one line in Young
/// Serif at 20 under it (``AteTextStyle/emptyTitle``; 40, then 26, read too loud, Eamon), and at most
/// one ink pill 22 below that, centred between the header and the tab bar. No second line, no
/// helper copy. The line's own breaks are the design's and are honoured.
///
/// The drawing is Paper Trail (Eamon, 6 Oct; made a system 26 Oct, `design/illustrations/`): one
/// paper thing, one food thing and at most one wink, in marker, ink only. When the band is too short
/// for it (a sheet, a landscape phone) the drawing steps aside and the line and pill stand alone.
/// Inside a page's section (a dish's reviews) it is drawn at ``Size/section``.
///
/// It fills the space it is given and centres itself in it; the screen gives it the band between its
/// header and the tab bar.
struct AteEmptyState: View {
    let line: String
    var art: AteEmptyArt?
    var pill: (title: String, action: () -> Void)?
    var size: Size = .page

    /// The drawing's two sizes: a whole page's band, or a section inside a page.
    enum Size: Sendable {
        case page, section

        var artHeight: CGFloat {
            self == .page ? AteEmptyStateMetrics.artHeight : AteEmptyStateMetrics.sectionArtHeight
        }

        var artGap: CGFloat {
            self == .page ? AteEmptyStateMetrics.artGap : AteEmptyStateMetrics.sectionArtGap
        }
    }

    init(
        line: String, art: AteEmptyArt? = nil, pill: (title: String, action: () -> Void)? = nil,
        size: Size = .page
    ) {
        self.line = line
        self.art = art
        self.pill = pill
        self.size = size
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
                AteEmptyDrawing(art: art, height: size.artHeight)
                    .padding(.bottom, size.artGap)
            }
            AteTitle(text: line, style: .emptyTitle)
            if let pill {
                AteInkPill(title: pill.title, size: .empty, action: pill.action)
                    .padding(.top, AteEmptyStateMetrics.gap)
            }
        }
    }
}

/// **Which drawing an empty state carries** — by what the emptiness *is*, never by screen, so the same
/// situation looks the same wherever it happens. Each is a scene in `design/illustrations/kit.js`,
/// rendered into `EmptyStates` as `Empty<rawValue>Ink` and `Empty<rawValue>Paper`.
enum AteEmptyArt: String, CaseIterable, Sendable {
    /// Your record has nothing yet: docket #0001 feeding out of the printer, a fork and the pencil.
    case journal = "Journal"
    /// No lists: an order spike with nothing on it but an olive.
    case lists = "Lists"
    /// A list (or the picker) with nothing on it: a numbered docket, every line blank, a glass's ring.
    case list = "List"
    /// Nothing kept: a blank docket with the save ribbon, and a takeaway pail.
    case saved = "Saved"
    /// Other people's writing, none yet: an empty ticket rail and a fly.
    case rail = "Rail"
    /// Nothing eaten here yet (a place, a category): the menu standing over a clean plate.
    case setting = "Setting"
    /// Nothing new, or nobody signed in: the counter bell, unrung, asleep.
    case bell = "Bell"
    /// A search or filter that matched nothing: a docket under a lens pulling a face.
    case search = "Search"
    /// Couldn't reach Ate: a tin-can telephone with its string snapped.
    case unplugged = "Unplugged"
    /// The thing is gone: a docket with a bite out of it.
    case torn = "Torn"
    /// No meals in your photos: two instant photos, one dark, one of an empty plate.
    case photos = "Photos"
}

/// The drawing itself: two template layers, the paper under the ink, so dark mode flips it whole —
/// ink becomes the light foreground and the paper becomes the plum slip.
///
/// The layers are trimmed top and bottom to what is drawn (`split.py`), so the line sits right under
/// the drawing (Eamon, 27 Oct: it floated apart). Every drawing is the stage's width, one scale for
/// all; its height is its own.
struct AteEmptyDrawing: View {
    let art: AteEmptyArt
    /// The stage's height (its width is this × ``AteEmptyStateMetrics/artAspect``): the empty state's
    /// own unless a screen gives the drawing more room (first run's start).
    var height: CGFloat = AteEmptyStateMetrics.artHeight

    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack {
            layer("Paper").foregroundStyle(AteColor.slip)
            layer("Ink").foregroundStyle(palette.fg)
        }
        .frame(width: width, height: width * trimmed)
        .accessibilityHidden(true)
    }

    private var width: CGFloat { height * AteEmptyStateMetrics.artAspect }

    /// The trimmed drawing's height over its width; the whole stage's if the image is missing.
    private var trimmed: CGFloat {
        guard let size = UIImage(named: "Empty\(art.rawValue)Ink")?.size, size.width > 0 else {
            return 1 / AteEmptyStateMetrics.artAspect
        }
        return size.height / size.width
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
    /// The drawing's stage height, and the air between what is drawn and the line: right next to it
    /// (Eamon, 27 Oct; it was 20 under the stage's own empty air, 40 to 75 in all).
    static let artHeight: CGFloat = 160
    static let artGap: CGFloat = 12
    /// …and inside a page's section.
    static let sectionArtHeight: CGFloat = 96
    static let sectionArtGap: CGFloat = 8
    /// The least an empty state is given inside a sheet, so a search that empties the rows leaves
    /// room for the line rather than collapsing the sheet under it.
    static let sheetMinimum: CGFloat = 260
    /// The artwork's canvas (180 × 140).
    static let artAspect: CGFloat = 180.0 / 140.0
}

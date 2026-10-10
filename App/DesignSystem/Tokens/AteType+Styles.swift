import SwiftUI

// MARK: - The named styles
//
// Every size in `design/v1` appears here once. A view asks for a role; it never asks for a number.

extension AteTextStyle {

    // Titles — Young Serif (10 Oct: Eamon swapped the headings off Bricolage). Tracking −2% at 24pt
    // and up, −1% at slip sizes, none below 18. Scores and avatar letters stay Bricolage 800.

    /// A screen's own name: "Feed", "You", "Search". 34pt (40 until Eamon's 6 Oct "some headings are too big"; every
    /// heading stepped down one notch here, never per screen).
    static let screenTitle = AteTextStyle(
        voice: .heading, size: 34, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// The place at the head of its own page — the biggest type in the app, because on the place
    /// page the place is the whole subject. 36pt (44 on `Restaurant.dc.html`, stepped down 6 Oct).
    static let placeTitle = AteTextStyle(
        voice: .heading, size: 36, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// A dish's aggregate, printed like a price on its own page. 64pt — the one number big enough
    /// to be read across a table (`Dish.dc.html`).
    static let dishScore = AteTextStyle(
        voice: .display, size: 64, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// The place at the head of the entry page — the biggest type in the app after a screen's own
    /// name, because on an entry the place IS the title. 32pt (38 before 6 Oct).
    static let entryPlace = AteTextStyle(
        voice: .heading, size: 32, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// A sheet's title. 26pt (30 before 6 Oct).
    static let sheetTitle = AteTextStyle(
        voice: .heading, size: 26, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title
    )
    /// The one line an empty state says. 26pt — under its drawing it is a caption to the picture, so
    /// it is well under ``screenTitle`` (Eamon, 6 Oct: the empty line was too big).
    static let emptyTitle = AteTextStyle(
        voice: .heading, size: 26, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title
    )
    /// The score a `Ratings` page is about, beside its stars. `.h` at 30.
    static let ratingsScore = AteTextStyle(
        voice: .display, size: 30, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// A number in a statement's cell: "142". 28pt.
    static let statValue = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.03, lineHeight: 1.0, textStyle: .title2
    )
    /// A pushed page's own name, beside a back arrow: "From your photos". 24pt.
    static let pageTitle = AteTextStyle(
        voice: .heading, size: 24, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )
    /// "Pick a handle." — first run's one question, at the size of a place heading its own page.
    static var handleTitle: AteTextStyle { placeTitle }
    /// What is typed into the handle field. `.h` at 30 — and at **−2%**, not `.h`'s own −3.5%:
    /// `Handle.dc.html` overrides the tracking on that one input, because a handle is read letter
    /// by letter and the title's tight setting closes `@e` up into one shape.
    static let handleField = AteTextStyle(
        voice: .heading, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title
    )
    /// A place heading a group of rows — the Saved shelf's place heads. 22pt.
    static let slipPlace = AteTextStyle(
        voice: .heading, size: 22, weight: 800, trackingEm: -0.01, lineHeight: 1.05, textStyle: .title2
    )
    /// **A dish in a slip's stack. 20pt** — the item itself, and the largest thing on a slip after
    /// its score. It wraps rather than truncating, so this never gets a line limit.
    static let slipDish = AteTextStyle(
        voice: .heading, size: 20, weight: 800, trackingEm: -0.01, lineHeight: 1.05, textStyle: .title3
    )
    /// …and the score beside it, printed like a price. 26pt at `.h`'s own line height of 1.
    static let slipScore = AteTextStyle(
        voice: .display, size: 26, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )

    // Controls — Bricolage 600/700.

    /// The default control label: segment, chip, row. 15pt.
    static let control = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// A row's own name in a list, and what is typed into a sheet's search field. `.ui` at 17.
    static let rowTitle = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// A smaller control label: segments, toolbar keys, handles. 14pt.
    static let controlSmall = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .subheadline
    )
    /// The one ink pill per sheet, and the Share button. 16pt/700.
    static let button = AteTextStyle(
        voice: .display, size: 16, weight: 700, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// The count in the journal header's coral badge. 11pt, capped — it lives in an 18pt disc.
    static let badge = AteTextStyle(
        voice: .display, size: 11, weight: 600, trackingEm: -0.01, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 13
    )
    /// "2h", "5 photos", a date above a slip. 13pt/500.
    static let meta = AteTextStyle(
        voice: .display, size: 13, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
    /// A dish's name under its tile in a small cluster — "Your top dishes". `.meta` at 12, in full ink:
    /// the name is the item, not a caption about it.
    static let tileCaption = AteTextStyle(
        voice: .display, size: 12, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .caption
    )
    /// A dietary tag's code in its chip on its own: the score pill's DM Mono 500, a step under a 16pt
    /// slip's score numeral (``TokenPillMetrics/dietScale``), capitals, `line-height:1` (Eamon, 9
    /// Oct: one family with the score, but never bigger than it). Capped — the chip is a fixed height.
    static let dietTag = AteTextStyle(
        voice: .mono, size: 11, weight: 500, trackingEm: 0.04, lineHeight: 1.0,
        textStyle: .caption2, maximumSize: 13, uppercase: true
    )
    /// The dish on the score slider's panel (`RaterSize`): `.h` at 22, `-.03em`, `line-height:1.05`
    /// — the slip's dish voice, a step up, so the name and the number read on one scale.
    static let sliderDish = AteTextStyle(
        voice: .heading, size: 22, weight: 800, trackingEm: -0.01, lineHeight: 1.05, textStyle: .title2
    )
    /// …and the live numeral beside it: `.h` at 28, `-.02em`, tabular.
    static let sliderScore = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )
    /// The letter on a photo-less dish's tile (`NoPhotoA`): `.h` 800 at 26 on a 56 tile, `-.02em`,
    /// scaled with the tile and never with Dynamic Type — it is a picture of the dish, not a label.
    static func dishInitial(tile side: CGFloat) -> AteTextStyle {
        AteTextStyle(
            voice: .heading, size: side * 26 / 56, weight: 800, trackingEm: 0, lineHeight: 1.0,
            textStyle: .title2, maximumSize: side * 26 / 56
        )
    }
    /// A letter in a byline's avatar circle. No tracking — a monogram is centred, not set.
    static let avatarInitial = AteTextStyle(
        voice: .display, size: 12, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .caption, maximumSize: 16
    )
    /// …and in the 36pt disc beside a dish review. 16pt, capped for the same reason.
    static let avatarInitialMedium = AteTextStyle(
        voice: .display, size: 16, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .body, maximumSize: 20
    )
    /// …and in the 76pt disc at the head of a profile. 34pt, capped for the same reason.
    static let avatarMonogram = AteTextStyle(
        voice: .display, size: 34, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .title, maximumSize: 44
    )

    // The person's words — Newsreader.

    /// The composer: the biggest the words ever are. 19pt.
    static let composerProse = AteTextStyle(
        voice: .prose, size: 19, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// The one line an empty slip or Welcome says under its title. 17pt — `.prose`'s own 1.5.
    static let proseLarge = AteTextStyle(
        voice: .prose, size: 17, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// The words in a journal slip. 16pt at `.prose`'s 1.5 — the entry page sets 1.45 by hand, and
    /// the two really are different in the markup.
    static let slipProse = AteTextStyle(
        voice: .prose, size: 16, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// Welcome's promise, set italic and centred. 19pt.
    static let proseQuote = AteTextStyle(
        voice: .prose, size: 19, weight: 400, italic: true, lineHeight: 1.3, textStyle: .body
    )
    /// The words on their own page (Entry) and in a journal slip. 16pt.
    static let prose = AteTextStyle(
        voice: .prose, size: 16, weight: 400, lineHeight: 1.45, textStyle: .body
    )

    // Receipts — DM Mono, and only here. Dish rows and scores only: no note under a line, ever.

    /// The numerals under the ratings histogram. 10pt DM Mono, plain — the only mono outside a
    /// receipt, because a chart's scale is a printed measure and reads as one.
    static let scaleLabel = AteTextStyle(
        voice: .mono, size: 10, weight: 400, lineHeight: 1.35, textStyle: .caption2, maximumSize: 14
    )
    /// A receipt label: the address, `ORDER #0142`, `3 DISHES`, `@eamon`. 11pt, uppercase, +8%.
    static let receiptLabel = AteTextStyle(
        voice: .mono, size: 11, weight: 400, trackingEm: 0.08, lineHeight: 1.35,
        textStyle: .caption2, maximumSize: 16, uppercase: true
    )
}

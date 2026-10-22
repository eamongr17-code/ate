import SwiftUI

// **The component kit's type** (rebuild phase 2a, `design/rebuild/*.html`). Every size a kit
// component sets that the older styles do not already name. A kit view asks for a role here; it
// never writes a number into `.ateText`.

extension AteTextStyle {
    /// The ink pill in a sheet — `.pill`: Bricolage 600 at 16, `line-height:1`.
    static let kitInkPill = AteTextStyle(
        voice: .display, size: 16, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .body
    )
    /// …and in an empty state, a step down: 600 at 15.
    static let kitInkPillSmall = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .subheadline
    )
    /// …and inside a row (a list invite's Accept, Decline): 600 at 14.
    static let kitInkPillRow = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .subheadline
    )
    /// The line under a receipt that is slow, unfinished or offline — on the composer's ink
    /// sheet: 500 at 17, `line-height:1.4` (design: receipt fallback states, 18 Oct)…
    static let kitReceiptFallback = AteTextStyle(
        voice: .display, size: 17, weight: 500, trackingEm: 0, lineHeight: 1.4, textStyle: .body
    )
    /// …and on the entry page, under its waiting rows: 500 at 15.
    static let kitReceiptFallbackPage = AteTextStyle(
        voice: .display, size: 15, weight: 500, trackingEm: 0, lineHeight: 1.4, textStyle: .subheadline
    )
    /// A photo's caption on somebody else's entry — `.capL b`: 600 at 17
    /// (design/rebuild/photo-dish-caption.html, B).
    static let kitPhotoCaptionDish = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .body
    )
    /// A dish's name floating over it in a photo of several — `.tag`: 600 at 16
    /// (design/rebuild/photo-dish-tags.html).
    static let kitPhotoDishName = AteTextStyle(
        voice: .display, size: 16, weight: 600, trackingEm: -0.01, lineHeight: 1.0, textStyle: .body
    )
    /// …and who and where under it — `.capL span`: 500 at 13.
    static let kitPhotoCaptionByline = AteTextStyle(
        voice: .display, size: 13, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
    /// A score token's numeral at a fixed size (`.tok` at `font-size:13px` on a card, `17px` on the
    /// hero) — DM Mono 500. Inline tokens size against their prose instead (``scoreToken(inProse:)``).
    static func kitScoreToken(_ size: CGFloat) -> AteTextStyle {
        AteTextStyle(voice: .mono, size: size, weight: 500, lineHeight: 1.0, textStyle: .footnote)
    }
    /// A shelf card's dish — `.card .t b`: 700 at 17, `line-height:1.15`, `-.02em`, two lines.
    static let kitShelfDish = AteTextStyle(
        voice: .display, size: 17, weight: 700, trackingEm: -0.02, lineHeight: 1.15, textStyle: .body
    )
    /// The hero's dish — `.hero .nm b`: 800 at 30 (34 before 6 Oct), `line-height:1.02`, `-.035em`.
    static let kitHeroDish = AteTextStyle(
        voice: .heading, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.02, textStyle: .largeTitle
    )
    /// …and its place — `.hero .nm span`: 500 at 15.
    static let kitHeroPlace = AteTextStyle(
        voice: .display, size: 15, weight: 500, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
    /// A ranked row's numeral — `.rk .n`: 800 at 30, `-.05em`.
    static let kitRankNumeral = AteTextStyle(
        voice: .display, size: 30, weight: 800, trackingEm: -0.05, lineHeight: 1.0, textStyle: .title2,
        maximumSize: 40
    )
    /// A ranked row's dish — `.rk .d b`: 800 at 18, `line-height:1.1`, `-.03em`.
    static let kitRankedDish = AteTextStyle(
        voice: .heading, size: 18, weight: 800, trackingEm: -0.01, lineHeight: 1.1, textStyle: .headline
    )
    /// A filter chip's value — `.chip`: 600 at 14, `line-height:1`.
    static let kitChip = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .subheadline,
        maximumSize: 20
    )
    /// A tab root's title on the header row — `.lt b`: 800 at 30 (34 before 6 Oct), `-.035em` (the native large
    /// title's own 34).
    static let kitRootTitle = AteTextStyle(
        voice: .heading, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// …and the city beside it — `.lt span`: 500 at 16, muted.
    static let kitRootSubtitle = AteTextStyle(
        voice: .display, size: 16, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .body
    )
    /// An inline bar title — a pushed page's name, and a tab root's title once it has collapsed into
    /// the centre of the bar — `.ntitle`/`.navt`/`.it b`: 600 at 17, `line-height:1.15`, `-.01em`.
    static let kitInlineTitle = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: -0.01, lineHeight: 1.15, textStyle: .headline,
        maximumSize: 22
    )
    /// …and the subtitle under it (the Feed's city, a byline's place) — `.it span`/`.navt small`: 500
    /// at 12, `line-height:1.2`, muted.
    static let kitInlineSubtitle = AteTextStyle(
        voice: .display, size: 12, weight: 500, trackingEm: 0, lineHeight: 1.2, textStyle: .caption,
        maximumSize: 16
    )
    /// A native tab bar item's label, at rest and selected — the old bar's 10.5 in Bricolage, bold
    /// when current. Set on the system bar's items through ``AteNativeChrome``.
    static let kitTabLabel = AteTextStyle(
        voice: .display, size: 10.5, weight: 500, trackingEm: 0, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 14
    )
    static let kitTabLabelSelected = AteTextStyle(
        voice: .display, size: 10.5, weight: 700, trackingEm: 0, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 14
    )
    /// A row in a native grouped list (Settings): `.it .tx`, 500 at 17.
    static let kitListRow = AteTextStyle(
        voice: .display, size: 17, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .body
    )
    /// The count on a glass control's badge — `.badge`: 600 at 10.5, capped (a 17pt disc).
    static let kitBadge = AteTextStyle(
        voice: .display, size: 10.5, weight: 600, trackingEm: 0, lineHeight: 1.0,
        textStyle: .caption2, maximumSize: 12
    )
    /// The letter on a photo-less dish's tile, at the size its slot draws it (26 on a row's 56, 22 on
    /// the menu's 48, 64 on a shelf card). A picture of the dish, so never scaled with Dynamic Type.
    static func kitThumbInitial(_ size: CGFloat) -> AteTextStyle {
        AteTextStyle(
            voice: .heading, size: size, weight: 800, trackingEm: 0, lineHeight: 1.0,
            textStyle: .title2, maximumSize: size
        )
    }

    // Share to Ate (`share-to-ate.html`) — the card that rises over another app.

    /// The card's title, "Save to Ate" — `.h` at `400 20px/1 'Young Serif'`, `.h`'s `-.035em`.
    static let kitShareTitle = AteTextStyle(
        voice: .heading, size: 20, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title3,
        maximumSize: 26
    )
    /// …and the word under its tick — `.done`: Young Serif at 20, `line-height:1`. Capped: it sits in a
    /// fixed 170 square.
    static let kitShareDone = AteTextStyle(
        voice: .heading, size: 20, weight: 800, trackingEm: 0, lineHeight: 1.0, textStyle: .title3,
        maximumSize: 26
    )
    /// Where a shared post came from — `.linkcard .ui`: Bricolage 600 at 15.
    static let kitLinkTitle = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.5, textStyle: .subheadline
    )
    /// A picked value's second line — a place's locality under its name: `.meta` at 12.
    static let kitPickDetail = AteTextStyle(
        voice: .display, size: 12, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .caption
    )
    /// The diet step's choices — `.pk` on `diet.html`'s first-run screen: 600 at 17, `line-height:1`.
    static let kitTogglePillLarge = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .body
    )
    /// The dish page's line for a code below the label — `.signal`: 500 at 14, `line-height:1.2`,
    /// muted ("Ordered by 2 vegan eaters").
    static let kitDietSignal = AteTextStyle(
        voice: .display, size: 14, weight: 500, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
}

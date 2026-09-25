import SwiftUI

/// **The design's colour, exactly as `docs/DESIGN.md` sets it down.** Dynamic colours in code, no
/// asset-catalog colours: the values are the spec, and a table in Swift can be read against the
/// table in the doc.
///
/// Two kinds of colour live here and they behave differently on purpose:
///
/// - **Roles** (ground, fg, muted, chip, field, hairline) are read through ``AtePalette`` from the
///   environment, because they are *relative to the surface you are on*. The same `fg` is white on
///   the ink ground and near-black on receipt paper. Never reach for the raw light/dark values below
///   at a call site — read the palette.
/// - **Accents** are absolute: identical in both modes, and always carrying ink text (design rule 5 —
///   colour is punctuation, never decoration).
enum AteColor {

    // MARK: - Accents (the same in both modes; always carry `ink` text)

    static let coral = Color(hex: 0xF0623F)
    /// Score tokens and the ratings histogram. The one colour a score is ever printed on.
    static let butter = Color(hex: 0xF6D365)
    static let green = Color(hex: 0x3ECF64)
    static let pink = Color(hex: 0xF490D4)
    static let sky = Color(hex: 0x36AEE6)
    static let lilac = Color(hex: 0xB9A5EA)
    static let destructive = Color(hex: 0xB3261E)

    /// Near-black. The text colour on every accent and on every piece of receipt paper, in both
    /// modes — and the fill of the `+` button and the one ink pill per sheet.
    static let ink = Color(hex: 0x24141F)

    /// The accents in the order a deterministic pick walks them (avatars, ratings bars). Index by a
    /// UUID hash, never by array position in a list.
    static let accents: [Color] = [coral, butter, green, pink, sky, lilac]

    // MARK: - Role sources
    //
    // The raw light/dark pairs the palettes are built from. `private` on purpose: the only way to a
    // role colour is through the palette, which is what makes "text on paper is always ink" true
    // without every call site remembering it.

    fileprivate static let groundLight = Color(hex: 0xEFEAE2)
    fileprivate static let groundDark = Color(hex: 0x17111B)
    /// The Ink boards' dark values (`MainInk`/`FeedInk`, 2026-09-25): a warm off-white rather than
    /// pure white, a lifted plum chip, and a field one step below it.
    fileprivate static let fgDark = Color(hex: 0xF4EFE9)
    fileprivate static let mutedLight = Color(hex: 0x5E5560)
    fileprivate static let mutedDark = Color(hex: 0xB9AFBC)
    fileprivate static let chipLight = Color.white
    fileprivate static let chipDark = Color(hex: 0x342A3A)
    fileprivate static let fieldLight = Color(hex: 0xE4DED4)
    fileprivate static let fieldDark = Color(hex: 0x231B24)

    /// Receipt paper. Its own token, and **dimmed in dark** so a white sheet doesn't burn a hole in
    /// the ink ground — but the text on it stays ``ink`` either way.
    static let paper = Color(light: .white, dark: Color(hex: 0xE6DFD3))
    /// A control surface *on* paper (a chip inside a receipt or slip).
    fileprivate static let paperChip = Color(hex: 0xF3F0EB)

    /// **A slip** — the one card the journal, the feed and a profile list, and the statement slip.
    /// White on linen; in dark it is its own plum card with light type on it (`.screen.dark .slip`),
    /// not the dimmed receipt paper. Receipts — the share card, the statement, the entry page — keep
    /// ``paper``.
    static let slip = Color(light: .white, dark: Color(hex: 0x231B24))

    // MARK: - Screen backgrounds

    /// The ground, adapting to the mode. The one role colour available outside the palette, because
    /// something has to paint the window before a palette exists.
    static let ground = Color(light: groundLight, dark: groundDark)
}

/// The six role colours, scoped to a surface. The direct equivalent of the prototype's CSS custom
/// properties, which is exactly how the design was drawn: `.slip` re-declares `--fg`, `--muted` and
/// `--chip` so a receipt reads as paper whatever the mode is.
struct AtePalette: Equatable, Sendable {
    var ground: Color
    var fg: Color
    var muted: Color
    var chip: Color
    var field: Color
    var hairline: Color
    /// What is written ON `fg` — the tab bar's `+`, the one ink pill per sheet. Its own role rather
    /// than "the ground", because on an accent ground the ground is coral and coral-on-ink is not a
    /// button, it is a mistake.
    var inverted: Color
    /// What dashed rules and dot leaders are drawn in, before their own opacity. The surface's `fg`
    /// everywhere but a dark slip, where the Ink boards set rules at white 22% rather than the
    /// 35% a straight `fg` would give (`.screen.dark .rule`).
    var rule: Color

    /// The app's ground, following light/dark.
    static let automatic = AtePalette(
        ground: AteColor.ground,
        fg: Color(light: AteColor.ink, dark: AteColor.fgDark),
        muted: Color(light: AteColor.mutedLight, dark: AteColor.mutedDark),
        chip: Color(light: AteColor.chipLight, dark: AteColor.chipDark),
        field: Color(light: AteColor.fieldLight, dark: AteColor.fieldDark),
        hairline: Color(light: AteColor.ink.opacity(0.14), dark: Color.white.opacity(0.16)),
        inverted: AteColor.ground,
        rule: Color(light: AteColor.ink, dark: AteColor.fgDark)
    )

    /// **A slip** — journal, feed and profile cards, and the statement slip. In light it is exactly
    /// receipt paper; in dark it is a plum card whose type turns light (`.screen.dark .slip`:
    /// `--fg:#F4EFE9; --muted:#B9AFBC; --chip:#342A3A; --field:#342A3A; --hair:white 12%`).
    static let slip = AtePalette(
        ground: AteColor.slip,
        fg: Color(light: AteColor.ink, dark: AteColor.fgDark),
        muted: Color(light: AteColor.mutedLight, dark: AteColor.mutedDark),
        chip: Color(light: AteColor.paperChip, dark: AteColor.chipDark),
        field: Color(light: AteColor.paperChip, dark: AteColor.chipDark),
        hairline: Color(light: AteColor.ink.opacity(0.14), dark: Color.white.opacity(0.12)),
        inverted: AteColor.slip,
        // 0.35 × 0.63 ≈ the boards' white 22% for a rule, and 0.3 × 0.63 ≈ their 20% for a leader.
        rule: Color(light: AteColor.ink, dark: Color.white.opacity(0.63))
    )

    /// Receipt paper: the ground dims in dark mode, everything written on it does not move.
    static let paper = AtePalette(
        ground: AteColor.paper,
        fg: AteColor.ink,
        muted: AteColor.mutedLight,
        chip: AteColor.paperChip,
        field: AteColor.paperChip,
        hairline: AteColor.ink.opacity(0.14),
        inverted: AteColor.paper,
        rule: AteColor.ink
    )

    /// **A control surface used as a whole screen's ground** — the composer, and every sheet.
    ///
    /// Identical to ``automatic`` except that `field` **recesses to the app ground**. The design's
    /// token table gives `chip` and `field` the same value in dark (`#2B2231`), so on a chip ground a
    /// field-coloured pill — the Place key, a sheet's search field — is invisible; Eamon caught
    /// exactly that driving the composer spike. A field is always a step *below* the surface it sits
    /// in, and this is what makes that true in both modes: linen-grey on white, ink on plum.
    static let surface: AtePalette = {
        var palette = AtePalette.automatic
        palette.ground = Color(light: AteColor.chipLight, dark: AteColor.chipDark)
        palette.field = Color(light: AteColor.fieldLight, dark: AteColor.groundDark)
        return palette
    }()

    /// An accent ground — Share, Welcome. Ink text, white chips, in both modes.
    static func accent(_ colour: Color) -> AtePalette {
        AtePalette(
            ground: colour,
            fg: AteColor.ink,
            muted: AteColor.ink.opacity(0.62),
            chip: .white,
            field: .white,
            hairline: AteColor.ink.opacity(0.18),
            inverted: .white,
            rule: AteColor.ink
        )
    }
}

extension EnvironmentValues {
    /// The role colours for the surface this view is on. Every design-system component reads this
    /// rather than naming a colour, so putting a component on paper is one modifier and no edits.
    @Entry var atePalette: AtePalette = .automatic
}

extension View {
    /// Puts the subtree on the app's ground.
    func ateGround() -> some View {
        environment(\.atePalette, .automatic)
            .background(AtePalette.automatic.ground)
    }

    /// Puts the subtree on a **control surface** used as a whole screen — the composer, a sheet.
    func ateSurface() -> some View {
        environment(\.atePalette, .surface)
            .background(AtePalette.surface.ground)
    }

    /// Puts the subtree on **receipt paper** — the ground dims in dark mode, the ink does not.
    /// Does not paint a background itself: a receipt's paper is drawn by its own shape (rounded top,
    /// torn bottom), so painting here would square the corners off.
    func atePaper() -> some View {
        environment(\.atePalette, .paper)
            .foregroundStyle(AtePalette.paper.fg)
    }

    /// Puts the subtree on **a slip** — the list card. Like ``atePaper()`` it paints nothing: a slip's
    /// silhouette (torn or whole) is drawn by its own shape.
    func ateSlip() -> some View {
        environment(\.atePalette, .slip)
            .foregroundStyle(AtePalette.slip.fg)
    }

    /// Puts the subtree on an accent ground — always ink text (design rule 5).
    func ateAccentGround(_ colour: Color) -> some View {
        environment(\.atePalette, .accent(colour))
            .foregroundStyle(AteColor.ink)
            .background(colour)
    }
}

// MARK: - Literals

extension Color {
    /// The design's hex values, written the way the doc writes them.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A dynamic colour built in code. No asset catalog: the spec is a table of pairs, and this keeps
    /// the pairs next to each other where they can be checked.
    init(light: Color, dark: Color) {
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

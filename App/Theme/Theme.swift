import SwiftUI

/// **The brand seam.** Every colour, type style, and spacing value in the app comes from here —
/// never from a literal at a call site. Today each token maps to a stock Apple semantic value, so
/// the app reads as pure native chrome (rule 1: brand is a coating, not a blocker). When Eamon
/// defines the brand, the `brand-designer` changes the mappings in this one file and the whole app
/// re-skins with no call-site edits.
///
/// Rules for adding a token:
/// - Name it by ROLE (`textSecondary`), never by appearance (`grey60`).
/// - Map it to a system semantic value, never a hardcoded RGB, until brand lands.
/// - If you're about to write `.padding(12)` or `.foregroundStyle(.gray)`, add a token instead.
public enum Theme {

    // MARK: - Colour

    public enum Color {
        /// App background behind scrolling content.
        public static let background = SwiftUI.Color(.systemBackground)
        /// Cards, rows, and other raised surfaces.
        public static let surface = SwiftUI.Color(.secondarySystemBackground)
        /// Hairlines and dividers.
        public static let separator = SwiftUI.Color(.separator)

        public static let textPrimary = SwiftUI.Color(.label)
        public static let textSecondary = SwiftUI.Color(.secondaryLabel)
        public static let textTertiary = SwiftUI.Color(.tertiaryLabel)

        /// The one expressive colour. Becomes the brand accent later.
        public static let accent = SwiftUI.Color.accentColor
        public static let destructive = SwiftUI.Color(.systemRed)
        public static let positive = SwiftUI.Color(.systemGreen)
    }

    // MARK: - Type

    /// Dynamic Type ramp. Always a system text style so accessibility sizes work for free.
    public enum Text {
        public static let screenTitle = Font.largeTitle.weight(.bold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let itemTitle = Font.headline
        public static let body = Font.body
        public static let detail = Font.subheadline
        public static let caption = Font.footnote
        /// A score shown inside a list row. Monospaced digits so a column of scores doesn't jitter
        /// as rows scroll. (The large receipt/card score numerals are separate tokens, added with
        /// the surfaces that need them.)
        public static let rowScore = Font.subheadline.weight(.medium).monospacedDigit()
    }

    // MARK: - Spacing

    /// 4pt grid. Use the role names, not the numbers.
    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let regular: CGFloat = 12
        public static let comfortable: CGFloat = 16
        public static let loose: CGFloat = 24
        public static let section: CGFloat = 32
    }

    // MARK: - Shape

    public enum Radius {
        public static let control: CGFloat = 10
        public static let card: CGFloat = 16
        public static let sheet: CGFloat = 24
    }
}

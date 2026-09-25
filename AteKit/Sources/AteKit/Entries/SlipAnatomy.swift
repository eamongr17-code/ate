import Foundation

/// **What one card shows, per surface** — the rules behind the one slip the journal, the feed and a
/// profile all draw (`docs/DESIGN.md`, 2026-09-25). Pure, so the thresholds are tested rather than
/// noticed on a screenshot.
///
/// Every surface: dish rows, the words, the photos, and a foot line of pin + place + suburb. What
/// differs is only the top row (the feed's byline), the right-hand end of the foot line (the
/// journal's date, a profile's age), and the feed's one editorial call about the words.
public enum SlipAnatomy {
    /// Where a slip is listed.
    public enum Surface: Sendable, Equatable {
        case journal, feed, profile
    }

    /// The feed drops the words once a visit has more than this many dishes: the dish stack is
    /// already the story, and three rows plus two lines of prose is a slip nobody scrolls past.
    public static let feedWordsMaximumDishes = 2

    /// Whether a slip on `surface` prints the person's words. Only the feed ever hides them, and only
    /// on a visit with more than ``feedWordsMaximumDishes`` dishes — the words themselves are never
    /// cut or rewritten, they are one tap away on the entry.
    public static func showsWords(on surface: Surface, dishCount: Int) -> Bool {
        switch surface {
        case .journal, .profile: true
        case .feed: dishCount <= feedWordsMaximumDishes
        }
    }

    /// The clamp on the words, where one is printed. The journal is your own record and prints them
    /// whole (Eamon, 2026-09-26); the feed and a profile are someone else's in a list, and stop at two
    /// lines with the rest one tap away. `nil` is no clamp.
    public static let clampedWordLines = 2

    public static func wordsLineLimit(on surface: Surface) -> Int? {
        switch surface {
        case .journal: nil
        case .feed, .profile: clampedWordLines
        }
    }
}

public extension EntryCard.Place {
    /// The suburb the foot line prints beside the name, in the muted voice: the place's
    /// **`locality`** — "CBD", "Collingwood North" — and never `city`, which can hold a mangled
    /// street address (`integration-design.md`). Blank prints nothing rather than a gap.
    var suburb: String? {
        guard let locality else { return nil }
        let trimmed = locality.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation

/// **One place, one day, one entry** (0103, `same-day-one-entry.html`): a post at a place the person
/// already posted that day is added to that entry instead of printing a second receipt. The composer
/// turns the post into an edit of the earlier entry, built here: their earlier words then the new ones
/// (as the server joins an answered tag's words), the earlier photos then the new ones, and everyone
/// tagged on either.
public enum SameDayMerge {
    /// The server's cap on an entry's photos (`entry_photos` positions 0…23).
    public static let photoLimit = 24

    /// The paragraph break between the earlier words and the new ones.
    public static let separator = "\n\n"

    /// The earlier words, a blank line, then the new ones, every pill and chip kept on its own words.
    /// Either side blank: the other alone, so a photos-only post adds no stray break.
    public static func composition(_ earlier: EntryComposition, adding later: EntryComposition) -> EntryComposition {
        if isBlank(later.plain) { return earlier }
        if isBlank(earlier.plain) { return later }
        let head = earlier.plain + separator
        let shift = head.utf16.count
        let moved = later.spans.map { span in
            EntryTokenSpan(
                token: span.token, span: TextSpan(location: span.span.location + shift, length: span.span.length)
            )
        }
        return EntryComposition(plain: head + later.plain, spans: earlier.spans + moved)
    }

    /// The entry's photos in their order, then the new ones, each once, at most ``photoLimit``.
    public static func photos(_ earlier: [EntryCard.Photo], adding later: [EntryEdit.Photo]) -> [EntryEdit.Photo] {
        var out = earlier.sorted { $0.position < $1.position }.map { EntryEdit.Photo.existing(url: $0.url) }
        for photo in later where out.contains(photo) == false {
            out.append(photo)
        }
        return Array(out.prefix(photoLimit))
    }

    /// Everyone on the earlier entry stays; anyone new is added after them.
    public static func people(_ earlier: [UUID], adding later: [UUID]) -> [UUID] {
        var out = earlier
        for person in later where out.contains(person) == false {
            out.append(person)
        }
        return out
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

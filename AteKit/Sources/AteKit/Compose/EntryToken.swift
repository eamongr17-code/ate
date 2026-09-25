import Foundation

/// A span of UTF-16 offsets. Our own type rather than `NSRange` so it is `Codable` and `Sendable`
/// and can be persisted with an entry; converts to `NSRange` at the UIKit seam.
public struct TextSpan: Hashable, Codable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public var endLocation: Int { location + length }

    public func contains(_ offset: Int) -> Bool { offset >= location && offset < endLocation }

    /// True when the two spans share at least one character, or when `other` is an empty span
    /// sitting strictly inside this one (a caret in the middle of a token).
    public func intersects(_ other: TextSpan) -> Bool {
        if other.length == 0 { return other.location > location && other.location < endLocation }
        if length == 0 { return location > other.location && location < other.endLocation }
        return other.location < endLocation && location < other.endLocation
    }
}

/// A place as a token knows it: **UUID-keyed** when it is a place we already have, name-only while
/// it is still just something the person typed (data-model rule — names are display strings, never
/// identifiers). `id == nil` is the "new place, not resolved yet" state, not an error.
public struct PlaceRef: Hashable, Codable, Sendable {
    public var id: UUID?
    public var name: String

    public init(id: UUID?, name: String) {
        self.id = id
        self.name = name
    }
}

/// What lives inline in the person's prose. Exactly two things, per the design: a score and a place.
public enum EntryTokenKind: Hashable, Codable, Sendable {
    case score(Rating)
    case place(PlaceRef)

    /// The characters this token occupies in the **plain** text — the words that are saved verbatim.
    /// A score prints like a price (one decimal, design rule 7); a place prints as its name.
    ///
    /// This is what makes the model degrade gracefully: a reader with no token support still sees
    /// "the tagliatelle al ragù 4.5 was unreal", not a placeholder.
    public var plainText: String {
        switch self {
        case .score(let rating): ScoreFormat.halfStep(rating.value)
        case .place(let place): place.name
        }
    }
}

/// One token, identified so a view can address it across edits (tap to reopen, replace a score)
/// without holding a range that the next keystroke invalidates.
public struct EntryToken: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var kind: EntryTokenKind
    /// The dish a **finished** entry's score token belongs to — the sorted line it was read from, so
    /// tapping the pill can open that dish's page. `nil` in the composer, in a draft, and on any
    /// entry the sorter has not resolved: those pills go nowhere, rather than somewhere guessed.
    public var dishID: UUID?

    public init(id: UUID = UUID(), kind: EntryTokenKind, dishID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.dishID = dishID
    }

    public var plainText: String { kind.plainText }

    public var score: Rating? {
        if case .score(let rating) = kind { return rating }
        return nil
    }

    public var place: PlaceRef? {
        if case .place(let place) = kind { return place }
        return nil
    }
}

/// A token and where it sits in the plain text.
public struct EntryTokenSpan: Identifiable, Hashable, Codable, Sendable {
    public var token: EntryToken
    /// Range in the **plain** text. `plain[span] == token.plainText` is the model's invariant.
    public var span: TextSpan

    public init(token: EntryToken, span: TextSpan) {
        self.token = token
        self.span = span
    }

    public var id: UUID { token.id }
}

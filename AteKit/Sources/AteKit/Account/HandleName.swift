import Foundation

/// **A handle, as the database will accept it.** `profiles.username` is `citext UNIQUE` with
/// `length between 1 and 30`, and the new-user trigger already sanitises its derived fallback to
/// `[a-z0-9_]` — so that is the alphabet, expressed here once rather than guessed at the field.
///
/// `Handle.dc.html` draws exactly two states: a green check, or nothing. There is no error line,
/// because design rule 1 forbids helper copy. That only stays honest if a handle can never be
/// *typed* into an illegal shape — so the field sanitises as you go (the `@` is furniture, not
/// input) and the check answers the only remaining question, "is it free".
public enum HandleName {
    /// `profiles_username_format`.
    public static let maximumLength = 30

    /// What the person typed, turned into what the column can hold: the `@` dropped, folded to
    /// lower case, anything outside `[a-z0-9_]` removed, capped at 30.
    ///
    /// Case-folding is not cosmetic — `username` is `citext`, so `Eamon` and `eamon` are the same
    /// handle and a field that let you type the first would report a free handle that then failed
    /// its unique index on insert.
    public static func sanitise(_ typed: String) -> String {
        var result = ""
        result.reserveCapacity(min(typed.count, maximumLength))
        for character in typed.lowercased() where isAllowed(character) {
            result.append(character)
            if result.count == maximumLength { break }
        }
        return result
    }

    /// Whether a sanitised handle is one the server will take.
    public static func isWellFormed(_ handle: String) -> Bool {
        handle.isEmpty == false
            && handle.count <= maximumLength
            && handle.allSatisfy(isAllowed)
    }

    /// How a handle is written wherever it is shown — the `@` belongs to the app, never to the row.
    public static func display(_ handle: String) -> String { "@" + handle }

    /// Two handles are the same handle when the column says so (`citext`).
    public static func isSame(_ one: String, _ other: String) -> Bool {
        sanitise(one) == sanitise(other)
    }

    private static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "_")
    }
}

/// What is known about the handle in the field, right now.
///
/// `unknown` is deliberately distinct from `taken`: a check that could not be made must not read as
/// a refusal, because the one thing worse than a slow handle screen is one that says your own name
/// is gone when the network hiccupped.
public enum HandleStatus: Sendable, Equatable {
    /// Nothing typed yet.
    case empty
    /// Typed, but not a handle the column would accept.
    case malformed
    /// A check is in the air.
    case checking
    case available
    case taken
    /// The check failed. Continue stays enabled — the server has the last word on the write.
    case unknown

    /// The green disc in `Handle.dc.html` — drawn for exactly one state.
    public var showsCheck: Bool { self == .available }

    /// Whether Continue can be pressed. `unknown` counts: refusing to let someone finish signing up
    /// because a boolean RPC timed out is a dead end, and the insert itself is the real gate.
    public var allowsContinue: Bool {
        switch self {
        case .available, .unknown: true
        case .empty, .malformed, .checking, .taken: false
        }
    }
}

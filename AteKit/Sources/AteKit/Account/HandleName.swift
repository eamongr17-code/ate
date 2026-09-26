import Foundation

/// **A handle, as the database will accept it.** `profiles.username` is `citext UNIQUE` with
/// `length between 1 and 30`, and the new-user trigger already sanitises its derived fallback to
/// `[a-z0-9_]` — so that is the alphabet, expressed here once rather than guessed at the field.
///
/// `Handle.dc.html` draws one state, the green check. The field carries three more — checking, taken
/// and malformed — as marks in the same 30pt slot, never as a line of copy (design rule 1).
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

    /// What the field holds after a keystroke: the `@` dropped and case folded (`citext` makes those
    /// two free), capped at 30 — but **anything else typed stays typed**. A space or a dot is kept
    /// so the field can show the handle is not one (``HandleStatus/malformed``) rather than quietly
    /// eating the keystroke and leaving the person wondering where it went.
    public static func normalise(_ typed: String) -> String {
        var trimmed = Substring(typed.lowercased())
        while trimmed.first == "@" { trimmed = trimmed.dropFirst() }
        return String(trimmed.prefix(maximumLength))
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

/// `setHandle` refused because the handle is somebody else's: the `profiles.username` unique index
/// (Postgres `23505`). The one write failure that means "taken" — anything else is a save that can
/// be tried again.
public struct HandleTaken: Error, Equatable, Sendable {
    public init() {}
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
    /// The check failed. The model asks again; Continue waits for an answer.
    case unknown

    /// The green disc in `Handle.dc.html` — drawn for exactly one state.
    public var showsCheck: Bool { self == .available }

    /// Whether Continue can be pressed: only on a handle that is well formed **and** known to be free.
    /// `unknown` does not count — the model keeps asking until it has an answer (``HandleModel``), so
    /// a dropped check is a pause, not a dead end.
    public var allowsContinue: Bool { self == .available }

    /// Which mark the field carries. Four, and visibly different, so the field never needs a line of
    /// copy to say what is wrong with it (design rule 1).
    public enum Mark: Sendable, Equatable {
        case none
        /// Asking — or asking again after a check that did not come back.
        case checking
        /// The artboard's green check.
        case available
        case taken
        case malformed
    }

    public var mark: Mark {
        switch self {
        case .empty: .none
        case .checking, .unknown: .checking
        case .available: .available
        case .taken: .taken
        case .malformed: .malformed
        }
    }
}

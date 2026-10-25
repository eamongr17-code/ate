import Foundation

/// **Two 6s in any two months** (Eamon, 25 Oct; `six_allowance`, 0091). The server is the rule — a
/// third 6 is saved as 5.0 whatever the app does — so this is only what the slider needs to say so
/// before the finger lifts. Unknown (offline, an older server) is no limit: the server still holds.
public struct SixAllowance: Equatable, Sendable, Decodable {
    /// How many 6s can still be given — on an edit, the entry's own 6s counted back in.
    public let left: Int
    /// When the next comes back, once none are left.
    public let nextAt: Date?

    public init(left: Int, nextAt: Date?) {
        self.left = left
        self.nextAt = nextAt
    }

    enum CodingKeys: String, CodingKey {
        case left = "sixes_left"
        case nextAt = "next_at"
    }

    /// The slider's lock on the pill `scoring`, or `nil` when it may still be a 6. Every *other* 6
    /// pill in the words is already spoken for; the pill being scored, if it is a 6 already, keeps it.
    public func lock(for composition: EntryComposition, scoring tokenID: UUID?) -> SixLock? {
        let others = composition.spans.filter { $0.token.score == .blownAway && $0.token.id != tokenID }.count
        return left - others > 0 ? nil : SixLock(nextAt: nextAt)
    }
}

/// **None left**: past 5.0 the sixth star comes out as an outline, the dish keeps 5.0, and the word
/// line says when the next one comes back.
public struct SixLock: Equatable, Sendable {
    public let nextAt: Date?

    public init(nextAt: Date?) {
        self.nextAt = nextAt
    }

    /// "Next 6 on 14 Dec" — or, when every 6 is in the words being written, "No 6s left".
    public func word(timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_AU")) -> String {
        guard let nextAt else { return "No 6s left" }
        var style = Date.FormatStyle(timeZone: timeZone).day().month(.abbreviated)
        style.locale = locale
        return "Next 6 on \(nextAt.formatted(style))"
    }
}

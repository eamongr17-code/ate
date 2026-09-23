import Foundation

/// **The body in both coordinate systems at once.**
///
/// The server counts **Unicode scalars** (Postgres counts code points, so the DB can verify every
/// offset it stores — `integration-design.md`), and everything on this side of the wire counts
/// **UTF-16**: `TextSpan`, `NSRange`, `NSAttributedString`, `UITextView`. One emoji earlier in the
/// words is enough to make the two disagree, and a pill one unit out sits on the wrong character.
///
/// So the conversion happens once per body, as a table, rather than by re-walking the string for
/// every lookup — and with it the small amount of searching that is still legitimate (the fallback
/// when the server could not point at something, always confined and always boundary-checked).
struct BodyOffsets {
    /// The body's UTF-16 units — the space ``TextSpan`` speaks.
    let units: [UInt16]

    /// `scalarStarts[i]` is the UTF-16 offset of scalar `i`. One entry longer than the scalar count,
    /// so the end of the body is addressable and a span ending there needs no special case.
    private let scalarStarts: [Int]

    init(_ body: String) {
        var units: [UInt16] = []
        var starts: [Int] = []
        units.reserveCapacity(body.utf16.count)
        starts.reserveCapacity(body.unicodeScalars.count + 1)
        for scalar in body.unicodeScalars {
            starts.append(units.count)
            units.append(contentsOf: scalar.utf16)
        }
        starts.append(units.count)
        self.units = units
        self.scalarStarts = starts
    }

    // MARK: - The wire's offsets

    /// A scalar offset + scalar length from the wire, as a UTF-16 span.
    ///
    /// `nil` when either half is missing, when the length is zero, or when the pair does not point
    /// inside this body — a stale or lying offset is a fallback, never a crash.
    func span(scalarOffset offset: Int?, scalarLength length: Int?) -> TextSpan? {
        guard let offset, let length, offset >= 0, length > 0, offset + length < scalarStarts.count else {
            return nil
        }
        let start = scalarStarts[offset]
        return TextSpan(location: start, length: scalarStarts[offset + length] - start)
    }

    /// The words a span covers — used to check what the server pointed at is still there, and to
    /// label a place pill with the body's own spelling rather than the catalogue's.
    func text(in span: TextSpan) -> String {
        guard span.location >= 0, span.endLocation <= units.count, span.length > 0 else { return "" }
        return String(decoding: units[span.location..<span.endLocation], as: UTF16.self)
    }

    // MARK: - Searching (the fallback, and inside a window)

    /// Every occurrence of `needle`, optionally confined to `window`.
    ///
    /// Case-insensitive on the ASCII range only: the sorter may have resolved "salmon roll" to the
    /// menu's "Salmon roll", and a pill that fails to appear because of one capital is worse than one
    /// found by a loose match. Nothing outside A–Z is folded, so a Turkish `İ` is left exactly as it
    /// is.
    func occurrences(of needle: String, within window: TextSpan? = nil) -> [TextSpan] {
        let target = Array(needle.utf16).map(Self.lowercased)
        let lower = max(0, window?.location ?? 0)
        let upper = min(units.count, window?.endLocation ?? units.count)
        guard target.isEmpty == false, upper - lower >= target.count else { return [] }
        var found: [TextSpan] = []
        for start in lower...(upper - target.count)
        where (0..<target.count).allSatisfy({ Self.lowercased(units[start + $0]) == target[$0] }) {
            found.append(TextSpan(location: start, length: target.count))
        }
        return found
    }

    /// True when this occurrence of a number is the WHOLE number rather than a slice of a longer one.
    /// A digit, `$`, `.` or `,` in front of it, or a digit after it, means "$14.50", "3.4.5", "1,4.5"
    /// — never somebody's score. Read against the whole body, so it holds inside a window too.
    func isWholeNumber(_ span: TextSpan) -> Bool {
        if span.location > 0 {
            let before = units[span.location - 1]
            if Self.isDigit(before) || before == 36 || before == 46 || before == 44 { return false }
        }
        if span.endLocation < units.count, Self.isDigit(units[span.endLocation]) { return false }
        return true
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func lowercased(_ unit: UInt16) -> UInt16 {
        (unit >= 65 && unit <= 90) ? unit + 32 : unit
    }
}

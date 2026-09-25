import Foundation

/// **The smallest edit that turns one display string into another.**
///
/// The editor writes every programmatic change through the text view's own `replace(_:withText:)`,
/// because that is what keeps UIKit's undo stack coherent. It used to replace the *whole document* to
/// do it, which made every such change — a spell of dictation included — an undo operation over
/// everything, and undoing it put back plain text: each pill that had been sitting untouched in the
/// sentence came back as a bare placeholder with no token behind it, and was deleted.
///
/// Replacing only what actually changed means undo takes back only what was added. A dictation into
/// the end of "Tipo 00 with Jess…" is one edit over the dictated run and nothing else, so one undo
/// removes exactly what was said and the place pill in front of it never moves.
public struct DisplayEdit: Hashable, Sendable {
    /// What to replace, in UTF-16 offsets of the **old** string.
    public var span: TextSpan
    /// What goes there.
    public var replacement: String

    public init(span: TextSpan, replacement: String) {
        self.span = span
        self.replacement = replacement
    }

    /// True when the two strings were already the same.
    public var isEmpty: Bool { span.length == 0 && replacement.isEmpty }

    /// The common prefix and suffix are left alone; the middle is the edit. Never splits a surrogate
    /// pair — an emoji half-replaced is invalid text — so the boundaries back off to whole characters.
    public static func between(_ old: String, _ new: String) -> DisplayEdit {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        // Back off a boundary that would leave the high half of a pair on one side.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let span = TextSpan(location: prefix, length: a.count - prefix - suffix)
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return DisplayEdit(span: span, replacement: replacement)
    }

    /// The edit applied to `old` — what the text view will hold afterwards.
    public func applied(to old: String) -> String {
        var units = Array(old.utf16)
        units.replaceSubrange(span.location..<span.endLocation, with: Array(replacement.utf16))
        return String(decoding: units, as: UTF16.self)
    }
}

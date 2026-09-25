import SwiftUI

/// A byline avatar: a letter on one of the six accents, picked deterministically from the person's
/// UUID — never from their position in a list, which would re-colour people as a feed loads.
struct AteAvatar: View {
    let userID: UUID
    let handle: String
    var side: CGFloat = AteMetrics.avatar
    /// The monogram's own size; the design draws 12 in a 28pt disc and 34 in a 76pt one.
    var textStyle: AteTextStyle = .avatarInitial

    var body: some View {
        Text(initials)
            .ateText(textStyle)
            .foregroundStyle(AteColor.ink)
            .frame(width: side, height: side)
            .background(AteColor.accents[AteAvatar.index(for: userID)], in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = handle.filter(\.isLetter)
        return String(letters.prefix(1)).uppercased()
    }

    /// Stable across launches and devices: the UUID's own bytes, not `hashValue` (which is seeded per
    /// process and would give the same person a different colour every launch).
    static func index(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in
            Int(bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }) % AteColor.accents.count
        }
    }
}

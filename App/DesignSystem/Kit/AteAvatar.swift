import SwiftUI

/// **An avatar**: a letter on one of the six accents, picked deterministically from the person's
/// UUID — never from their position in a list, which would re-colour people as a feed loads.
/// Three sizes (``Size``): a byline's 28, a dish review's 36, a profile's 76.
struct AteAvatar: View {
    let userID: UUID
    let handle: String
    var side: CGFloat = AteMetrics.avatar
    /// The monogram's own size; the design draws 12 in a 28pt disc and 34 in a 76pt one.
    var textStyle: AteTextStyle = .avatarInitial
    /// Their photo, when the row that named them carried one. ``AteAvatarDirectory`` knows better
    /// for anyone whose photo changed since (yours, set in Settings, at once).
    var url: URL?

    var body: some View {
        Text(initials)
            .ateText(textStyle)
            .foregroundStyle(AteColor.ink)
            .frame(width: side, height: side)
            .background(AteColor.accents[AteAvatar.index(for: userID)], in: .circle)
            .overlay {
                // The photo over the letter: until it arrives (or if it never does) the letter shows.
                if let photo {
                    AteRemotePhoto(url: photo, size: .thumbnail, placeholder: .clear)
                        .frame(width: side, height: side)
                        .clipShape(.circle)
                }
            }
            .accessibilityHidden(true)
    }

    /// Noted since wins over what the row carried — including a photo since removed.
    private var photo: URL? {
        switch AteAvatarDirectory.shared.known(userID) {
        case .some(let noted): noted
        case .none: url
        }
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

extension AteAvatar {
    /// The sizes an avatar is drawn at, each with its own monogram.
    enum Size: Equatable {
        /// A byline — a slip's, a place visit's. 28, the letter 12.
        case byline
        /// Beside a dish review. 36, the letter 16.
        case review
        /// At the head of a profile. 76, the letter 34.
        case profile
    }

    init(userID: UUID, handle: String, size: Size, url: URL? = nil) {
        switch size {
        case .byline: self.init(userID: userID, handle: handle, url: url)
        case .review: self.init(userID: userID, handle: handle, side: 36, textStyle: .avatarInitialMedium, url: url)
        case .profile: self.init(userID: userID, handle: handle, side: 76, textStyle: .avatarMonogram, url: url)
        }
    }
}

/// **Whose photo is what, now.** A row carries the avatar its author had when it was read; a photo
/// set since — your own, in Settings — is noted here and wins everywhere the person is drawn, so
/// changing it shows across the app at once rather than after every list is read again.
@MainActor
@Observable
final class AteAvatarDirectory {
    static let shared = AteAvatarDirectory()

    /// `.some(nil)`: known to have no photo now.
    private var urls: [UUID: URL?] = [:]

    /// Their photo as last noted — `nil` when nothing was, `.some(nil)` when they have none.
    func known(_ userID: UUID) -> URL?? { urls[userID] }

    /// What the server says their photo is now. `nil` (no photo) is noted too: a removed photo stops
    /// showing.
    func note(_ userID: UUID, url: URL?) {
        guard urls[userID] != .some(url) else { return }
        urls[userID] = .some(url)
    }
}

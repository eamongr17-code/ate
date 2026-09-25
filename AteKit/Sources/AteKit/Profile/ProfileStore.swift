import Foundation
import Observation

/// **Somebody else's page**: the header, and their entries under it.
///
/// The header and the list load independently, because they fail independently — a profile with no
/// entries yet is a real, drawable page, and a header that 404s (blocked, deleted) must not take a
/// loaded list down with it.
@MainActor
@Observable
public final class ProfileStore {

    public enum Header: Sendable, Equatable {
        case loading
        case ready(ProfileSummary)
        /// Blocked, deleted, or never there. Every read tolerates a missing author (contract).
        case unavailable
    }

    public let userID: UUID
    public private(set) var header: Header = .loading
    public let entries: EntryListStore
    /// True once ``block()`` has succeeded — the page is done, and whoever pushed it pops it.
    public private(set) var isBlocked = false

    private let profiles: any ProfileReading
    private var hasLoadedHeader = false

    public init(
        userID: UUID,
        profiles: any ProfileReading,
        pageSize: Int = 20,
        savedDishes: SavedDishBroadcast? = nil
    ) {
        self.userID = userID
        self.profiles = profiles
        self.entries = EntryListStore(
            pageSize: pageSize,
            fallbackMessage: "Couldn't load these entries.",
            savedDishes: savedDishes
        ) { [profiles] cursor, size in
            try await profiles.entriesPage(authorID: userID, after: cursor, pageSize: size)
        }
    }

    public func load() async {
        async let header: Void = loadHeaderIfNeeded()
        async let list: Void = entries.loadIfNeeded()
        _ = await (header, list)
    }

    public func refresh() async {
        hasLoadedHeader = false
        async let header: Void = loadHeaderIfNeeded()
        async let list: Void = entries.refresh()
        _ = await (header, list)
    }

    private func loadHeaderIfNeeded() async {
        guard hasLoadedHeader == false else { return }
        do {
            let summary = try await profiles.profile(id: userID)
            hasLoadedHeader = true
            header = .ready(summary)
        } catch is CancellationError {
            return
        } catch {
            hasLoadedHeader = true
            header = .unavailable
        }
    }

    /// The handle, once it is known — what the actions sheet titles itself with.
    public var username: String? {
        if case .ready(let summary) = header { return summary.username }
        return nil
    }

    /// Whether this page is about somebody else. `is_me` is the server's answer, not a comparison
    /// of ids on the client, and until the header lands the answer is "not yet" — a control that
    /// might be self-block is not drawn on a guess.
    public var isSomebodyElse: Bool {
        if case .ready(let summary) = header { return summary.isMe == false }
        return false
    }

    // MARK: - Actions

    /// Block. Returns whether it went through, because what happens next — popping this page and
    /// refetching the feed behind it — is the caller's, and it must not happen on a failure.
    @discardableResult
    public func block() async -> Bool {
        do {
            try await profiles.block(userID: userID)
            isBlocked = true
            entries.removeAuthor(userID)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func report(reason: String? = nil, note: String? = nil) async -> Bool {
        do {
            try await profiles.report(profileID: userID, reason: reason, note: note)
            return true
        } catch {
            return false
        }
    }
}

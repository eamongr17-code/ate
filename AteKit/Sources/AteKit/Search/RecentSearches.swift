import Foundation
import Observation

/// One thing somebody searched for.
public struct RecentSearch: Codable, Hashable, Sendable, Identifiable {
    public let text: String

    /// Case-blind, so "Ragu" and "ragu" are one recent search.
    public var id: String { text.lowercased() }

    public init(text: String) {
        self.text = text
    }
}

/// **What a search field shows before a character is typed**: your recent searches, newest first.
///
/// A search is remembered when it is *used*: a result opened from it, or the Search key pressed. A
/// keystroke on the way to a word is not a search. Kept on the phone, per person and per search
/// field (`surface`), at most ``limit``; searching the same words again moves them to the top rather
/// than listing them twice.
@MainActor
@Observable
public final class RecentSearches {
    public private(set) var items: [RecentSearch]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let minimumLength: Int

    public static let defaultLimit = 8

    /// `owner` keys the list to one person, so somebody signing in on this phone never sees the last
    /// person's searches. `nil` is somebody reading signed out.
    public init(
        owner: UUID?,
        surface: String = "search",
        defaults: UserDefaults = .standard,
        limit: Int = RecentSearches.defaultLimit,
        minimumLength: Int = 2
    ) {
        self.defaults = defaults
        self.key = Self.key(for: owner, surface: surface)
        self.limit = limit
        self.minimumLength = minimumLength
        self.items = Self.decode(defaults.data(forKey: key))
    }

    /// Remembers `text`. Below the search's own two-character floor it was never a search, and is not
    /// remembered.
    public func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return }
        let search = RecentSearch(text: trimmed)
        var next = items.filter { $0.id != search.id }
        next.insert(search, at: 0)
        items = Array(next.prefix(limit))
        save()
    }

    public func remove(_ search: RecentSearch) {
        items.removeAll { $0.id == search.id }
        save()
    }

    public func clear() {
        items = []
        save()
    }

    // MARK: - On the phone

    static func key(for owner: UUID?, surface: String = "search") -> String {
        "ate.\(surface).recents." + (owner?.uuidString.lowercased() ?? "browsing")
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }

    private static func decode(_ data: Data?) -> [RecentSearch] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RecentSearch].self, from: data)) ?? []
    }
}

import Foundation
import Observation

/// One thing somebody searched for: the words, and the scope they were looking in.
public struct RecentSearch: Codable, Hashable, Sendable, Identifiable {
    public let text: String
    public let scope: SearchScope

    /// Case-blind, so "Ragu" and "ragu" are one recent search.
    public var id: String { text.lowercased() }

    public init(text: String, scope: SearchScope) {
        self.text = text
        self.scope = scope
    }
}

/// **What the Search tab shows before a character is typed** (rebuild, Eamon 3 Oct): your recent
/// searches, newest first — never a location list, because Search never asks where the phone is.
///
/// A search is remembered when it is *used*: a result opened from it, or the Search key pressed. A
/// keystroke on the way to a word is not a search. Kept on the phone, per person, at most
/// ``limit``; searching the same words again moves them to the top rather than listing them twice.
@MainActor
@Observable
public final class RecentSearches {
    public private(set) var items: [RecentSearch]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let limit: Int

    public static let defaultLimit = 8

    /// `owner` keys the list to one person, so somebody signing in on this phone never sees the last
    /// person's searches. `nil` is somebody reading signed out.
    public init(owner: UUID?, defaults: UserDefaults = .standard, limit: Int = RecentSearches.defaultLimit) {
        self.defaults = defaults
        self.key = Self.key(for: owner)
        self.limit = limit
        self.items = Self.decode(defaults.data(forKey: Self.key(for: owner)))
    }

    /// Remembers `text` as searched in `scope`. Below the search's own two-character floor it was
    /// never a search, and is not remembered.
    public func record(_ text: String, scope: SearchScope) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= scope.minimumQueryLength else { return }
        let search = RecentSearch(text: trimmed, scope: scope)
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

    static func key(for owner: UUID?) -> String {
        "ate.search.recents." + (owner?.uuidString.lowercased() ?? "browsing")
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }

    private static func decode(_ data: Data?) -> [RecentSearch] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RecentSearch].self, from: data)) ?? []
    }
}

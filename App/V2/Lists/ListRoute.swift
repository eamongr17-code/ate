import AteKit
import Foundation

/// **One of your lists, as a route** — its id, and the shelf's summary when it was opened from a
/// card, so the page draws its name and count before its read answers.
struct ListRoute: Hashable {
    let id: UUID
    var summary: UserList?

    init(_ list: UserList) {
        id = list.id
        summary = list
    }

    init(id: UUID) {
        self.id = id
        summary = nil
    }

    // One list is one place, whatever summary it was opened with.
    static func == (lhs: ListRoute, rhs: ListRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

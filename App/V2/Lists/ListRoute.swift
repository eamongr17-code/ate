import AteKit
import Foundation

/// **One of your lists, as a route** — its id, and the shelf's summary when it was opened from a
/// card, so the page draws its name and count before its read answers. A list just made opens with
/// its picker already rising over it (`picksOnOpen`).
struct ListRoute: Hashable {
    let id: UUID
    var summary: UserList?
    var picksOnOpen = false

    init(_ list: UserList, picksOnOpen: Bool = false) {
        id = list.id
        summary = list
        self.picksOnOpen = picksOnOpen
    }

    init(id: UUID) {
        self.id = id
        summary = nil
    }

    // One list is one place, whatever summary it was opened with.
    static func == (lhs: ListRoute, rhs: ListRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

import AteKit
import Foundation

/// The Lists screens' words — each said once, here.
enum ListsCopy {
    static let newList = "New list"
    static let rename = "Rename"
    static let deleteList = "Delete list"
    static let delete = "Delete"
    static let remove = "Remove"
    static let undo = "Undo"
    static let addDishes = "Add dishes"
    static let addToList = "Add to a list"
    static let makeList = "Make a list"
    static let emptyShelf = "No lists\nyet."
    static let emptyList = "Nothing on\nit yet."
    static let emptyPicker = "Nothing to\nadd yet."
    static let noMatch = "Nothing\nlike that."
    static let unreachable = "Couldn't\nreach Ate."
    static let tryAgain = "Try again"
    static let searchPrompt = "Search your dishes"
    static let namePrompt = "Name"
    static let done = "Done"

    static func dishes(_ count: Int) -> String {
        count == 1 ? "1 dish" : "\(count) dishes"
    }

    static func addCount(_ count: Int) -> String {
        count == 1 ? "Add 1 dish" : "Add \(count) dishes"
    }

    static func addToLists(_ count: Int) -> String {
        count == 1 ? "Add to 1 list" : "Add to \(count) lists"
    }

    static func confirmDelete(_ name: String) -> String {
        "Delete \(name)?"
    }

    /// The one line a refusal says, in the app's standard alert — `nil` where nothing needs saying
    /// (a list already gone, a session ended).
    static func failure(_ error: ListsError) -> String? {
        switch error {
        case .listCap: "50 lists is the most you can have."
        case .itemCap: "A list holds 100 dishes at most."
        case .listNotFound, .signedOut: nil
        case .badName, .reorderMismatch, .badInput, .lineNotFound, .unreachable: "Couldn't reach Ate."
        }
    }
}

/// The Lists screens' numbers.
enum ListsMetrics {
    static let skeletonCards = 3
    static let skeletonRows = 6
    /// An empty state never squeezes below this, however small the screen.
    static let emptyMinimum: CGFloat = 320
    /// The list name's limit on the phone (the server allows 80).
    static let nameLimit = 60
    /// How long the list page's Undo stays open — Saved's four seconds.
    static let undoLifetime = Duration.seconds(4)
    /// The receipt prints ten lines; past ten, "+N more" in fine print.
    static let receiptLines = 10
}

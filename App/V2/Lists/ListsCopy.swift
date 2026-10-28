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
    static let share = "Share"
    static let addToList = "Add to a list"
    static let whichDishes = "Which dishes?"
    static let next = "Next"
    static let emptyShelf = "No lists\nyet."
    static let emptyPicker = "Nothing to\nadd yet."
    static let noMatch = "Nothing\nlike that."
    static let unreachable = "Couldn't\nreach Ate."
    static let tryAgain = "Try again"
    static let searchPrompt = "Search your dishes"
    static let namePrompt = "Name"
    static let done = "Done"
    // Covers and people (`list-cover-edit.html`).
    static let changeCover = "Change cover"
    static let automatic = "Automatic"
    static let uploadFromPhotos = "Upload from Photos"
    static let uploadedPhoto = "Uploaded photo"
    static let dishPhotos = "Dish photos"
    /// What Automatic draws: the mosaic of the first four, else the first photo whole.
    static func automaticFrom(photos: Int) -> String? {
        switch photos {
        case 0: nil
        case 1..<4: "First dish photo"
        default: "First 4 dish photos"
        }
    }
    static let addPeople = "Add people"
    static let peopleOnThisList = "People on this list"
    static let peopleYouAteWith = "People you've eaten with"
    static let searchHandles = "Search handles"
    static let leaveList = "Leave list"
    static let leave = "Leave"
    static let listInvites = "List invites"
    static let accept = "Accept"
    static let decline = "Decline"
    static let photoFailed = "Couldn't use that photo."

    static func dishes(_ count: Int) -> String {
        count == 1 ? "1 dish" : "\(count) dishes"
    }

    static func addCount(_ count: Int) -> String {
        count == 1 ? "Add 1 dish" : "Add \(count) dishes"
    }

    static func addToLists(_ count: Int) -> String {
        count == 1 ? "Add to 1 list" : "Add to \(count) lists"
    }

    static func invitePeople(_ count: Int) -> String {
        count == 1 ? "Invite 1 person" : "Invite \(count) people"
    }

    static func confirmLeave(_ name: String) -> String {
        "Leave \(name)?"
    }

    /// "**@eamon** invited you to **Date night**" — a notification row's sentence.
    static func invited(by handle: String, to name: String) -> [AteNotificationRun] {
        [.strong("@\(handle)"), .plain(" invited you to "), .strong(name)]
    }

    /// The owner line: you (or the owner) first, then everyone who accepted.
    static func byline(_ handles: [String]) -> String {
        handles.joined(separator: ", ")
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
        case .peopleCap: "A list can have 20 people at most."
        case .listNotFound, .inviteNotFound, .signedOut: nil
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
}

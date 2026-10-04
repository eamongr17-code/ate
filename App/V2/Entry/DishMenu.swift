import AteKit
import SwiftUI

/// A place's menu, as the dish sheet offers it — read before the sheet rises.
@MainActor
@Observable
final class DishMenu {
    private(set) var dishes: [PlaceDish] = []
    /// Whether the menu has answered. An entry with no place has nothing to ask, which is an answer.
    private(set) var hasAnswered = false

    private let directory: any PlaceDirectory
    private let placeID: UUID?

    init(directory: any PlaceDirectory, placeID: UUID?) {
        self.directory = directory
        self.placeID = placeID
        hasAnswered = placeID == nil
    }

    func load() async {
        guard let placeID, hasAnswered == false else { return }
        dishes = (try? await directory.dishes(atPlace: placeID, limit: 50)) ?? []
        hasAnswered = true
    }

    /// The menu's dish with this name, if it has one.
    func match(_ name: String) -> UUID? {
        dishes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}

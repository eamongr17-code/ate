import Foundation

/// **What the page you tapped from already knew about a dish** (round 6, Eamon: "sometimes when
/// tapping into a dish overview, the page doesn't load fast enough and some things feel weird").
///
/// The dish page draws from this the moment it is pushed — the name, the place, a photo, the
/// aggregate when the row showed one — and only its read fills in the rest, in slots already drawn at
/// their final size. Never a guess: a field the surface did not show is `nil`, and the page draws a
/// still skeleton there rather than inventing it. A person's own score on a slip is **not** the
/// dish's aggregate, so a slip never passes one (design rule 7).
public struct DishPreview: Sendable, Equatable {
    public let dishID: UUID
    public var name: String
    public var restaurantID: UUID?
    public var restaurantName: String?
    /// The dish's aggregate, only when the surface printed that very number (a menu row, a search
    /// row) — never somebody's own score.
    public var score: Double?
    /// A photo of the dish the surface showed, if any.
    public var photoURL: String?
    /// Whether the dish has photos at all, when the surface knows (`nil` = it does not).
    public var hasPhotos: Bool?

    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID? = nil,
        restaurantName: String? = nil,
        score: Double? = nil,
        photoURL: String? = nil,
        hasPhotos: Bool? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.score = score
        self.photoURL = photoURL
        self.hasPhotos = hasPhotos ?? (photoURL == nil ? nil : true)
    }

    /// Everything a loaded page knew — so a dish opened a second time draws whole at once.
    public init(_ summary: DishSummary) {
        self.init(
            dishID: summary.dishID,
            name: summary.name,
            restaurantID: summary.restaurantID,
            restaurantName: summary.restaurantName,
            score: summary.score,
            photoURL: summary.photos.first?.url ?? summary.coverURLString,
            hasPhotos: summary.photos.isEmpty == false || summary.coverURLString != nil
        )
    }

    /// Two previews of one dish, the better-informed field winning each time.
    func merged(over older: DishPreview) -> DishPreview {
        DishPreview(
            dishID: dishID,
            name: name.isEmpty ? older.name : name,
            restaurantID: restaurantID ?? older.restaurantID,
            restaurantName: restaurantName ?? older.restaurantName,
            score: score ?? older.score,
            photoURL: photoURL ?? older.photoURL,
            hasPhotos: hasPhotos ?? older.hasPhotos
        )
    }
}

/// **The previews on hand** — noted by the rows a dish can be opened from, and by a dish page once
/// it has loaded; read by the dish page as it is pushed. Bounded: the oldest go first.
@MainActor
public final class DishPreviews {
    public static let shared = DishPreviews()

    private var previews: [UUID: DishPreview] = [:]
    private var order: [UUID] = []
    private let capacity: Int

    public init(capacity: Int = 300) {
        self.capacity = capacity
    }

    public func note(_ preview: DishPreview) {
        if let older = previews[preview.dishID] {
            previews[preview.dishID] = preview.merged(over: older)
            order.removeAll { $0 == preview.dishID }
        } else {
            previews[preview.dishID] = preview
        }
        order.append(preview.dishID)
        while order.count > capacity {
            previews.removeValue(forKey: order.removeFirst())
        }
    }

    public func preview(for dishID: UUID) -> DishPreview? {
        previews[dishID]
    }
}

/// **A place's name, as the row that opened it printed it** (round 6) — the place page draws its
/// title from this at once, and the chips, the menu and the visits wait as still shapes. Noted by the
/// rows a place is opened from, and by a place page once it has loaded.
@MainActor
public final class PlacePreviews {
    public static let shared = PlacePreviews()

    private var names: [UUID: String] = [:]
    private var order: [UUID] = []
    private let capacity: Int

    public init(capacity: Int = 300) {
        self.capacity = capacity
    }

    public func note(_ restaurantID: UUID, name: String) {
        guard name.isEmpty == false else { return }
        names[restaurantID] = name
        order.removeAll { $0 == restaurantID }
        order.append(restaurantID)
        while order.count > capacity {
            names.removeValue(forKey: order.removeFirst())
        }
    }

    public func name(for restaurantID: UUID) -> String? {
        names[restaurantID]
    }
}

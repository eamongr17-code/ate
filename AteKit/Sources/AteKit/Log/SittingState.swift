import Foundation

/// The restaurant a sitting is at. Resolved once, at the WHERE step, and never asked again (§4.2).
public struct SittingRestaurant: Sendable, Hashable, Codable {
    public let id: UUID
    /// Display string. Never an identifier.
    public let name: String
    /// `nil` renders nothing — never an empty separator dot.
    public let suburb: String?

    public init(id: UUID, name: String, suburb: String? = nil) {
        self.id = id
        self.name = name
        self.suburb = suburb
    }
}

/// Where a staged photo is in its life (§3.5, §5.1). The upload starts the moment the photo is
/// picked, so by the time Post is tapped it is usually already `uploaded` and costs nothing.
public enum PhotoUploadState: Sendable, Hashable, Codable {
    case uploading
    case uploaded(urlString: String)
    /// Never blocks Post — the review posts without the photo (§5.1).
    case failed

    public var uploadedURLString: String? {
        if case .uploaded(let urlString) = self { return urlString }
        return nil
    }

    public var isInFlight: Bool { self == .uploading }
}

/// A photo staged against one dish card. The local file survives an abandon-and-resume, so the draft
/// keeps the *file name* (in the caches directory keyed by draft id), not an absolute path that would
/// break the next time the container moves.
public struct SittingPhoto: Sendable, Hashable, Codable {
    public let localFileName: String
    public var uploadState: PhotoUploadState

    public init(localFileName: String, uploadState: PhotoUploadState = .uploading) {
        self.localFileName = localFileName
        self.uploadState = uploadState
    }
}

/// One dish card in a sitting.
///
/// **`id` is the review's id**, minted here rather than by the server. That single decision is what
/// makes the whole post path idempotent: the storage path for the photo is known before the upload
/// starts, a partial batch can be retried per-row without duplicating anything (§6.4), and the
/// receipt can deep-link to the review it just wrote without a read-back.
public struct SittingDish: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let dishID: UUID
    /// Display string.
    public let dishName: String
    /// `nil` is the pre-interaction "unset" state — distinct from any score, and unpostable (§2.2).
    public var score: Rating?
    public var note: String
    public var photo: SittingPhoto?

    public init(
        id: UUID = UUID(),
        dishID: UUID,
        dishName: String,
        score: Rating? = nil,
        note: String = "",
        photo: SittingPhoto? = nil
    ) {
        self.id = id
        self.dishID = dishID
        self.dishName = dishName
        self.score = score
        self.note = note
        self.photo = photo
    }

    public var trimmedNote: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var isRated: Bool { score != nil }

    /// §7: what makes a sitting worth offering to save.
    public var hasContent: Bool { isRated || trimmedNote != nil || photo != nil }
}

/// One restaurant, 1…n dish drafts, one Post (§4). Entirely client-side — there is no `sittings`
/// table and the concept never reaches the server; it posts n `reviews` rows and disappears.
///
/// A value type with no dependencies, so every rule the spec names (duplicate guard, soft cap,
/// post-enablement, ordering) is asserted in `SittingStateTests` rather than driven through a view.
public struct SittingState: Sendable, Hashable, Codable {
    /// §4.3: "Soft cap 8 cards". Not enforced server-side — it's a nudge to post, not a limit.
    public static let softCap = 8

    public let restaurant: SittingRestaurant
    public private(set) var dishes: [SittingDish]
    /// When the sheet was opened — the clock behind `log_posted(seconds_from_open)`, the friction
    /// north-star (§8).
    public let startedAt: Date

    public init(restaurant: SittingRestaurant, dishes: [SittingDish] = [], startedAt: Date = Date()) {
        self.restaurant = restaurant
        self.dishes = dishes
        self.startedAt = startedAt
    }

    // MARK: - Adding

    /// What happened when a dish came back from the WHAT step.
    public enum AddOutcome: Sendable, Hashable {
        /// A new card was appended at `index`.
        case added(cardID: UUID, index: Int)
        /// §4.3 duplicate guard: the dish is already on the canvas. No second card — the caller
        /// scrolls to and flashes the existing one.
        case duplicate(cardID: UUID, index: Int)
        /// §4.3 soft cap reached.
        case atCapacity
    }

    @discardableResult
    public mutating func add(dishID: UUID, dishName: String, cardID: UUID = UUID()) -> AddOutcome {
        if let index = dishes.firstIndex(where: { $0.dishID == dishID }) {
            return .duplicate(cardID: dishes[index].id, index: index)
        }
        guard canAddAnother else { return .atCapacity }
        dishes.append(SittingDish(id: cardID, dishID: dishID, dishName: dishName))
        return .added(cardID: cardID, index: dishes.count - 1)
    }

    /// §4.3: "No reorder. Order is arrival order." — so adding is always an append and there is no
    /// insert-at.
    public var canAddAnother: Bool { dishes.count < Self.softCap }

    // MARK: - Removing

    /// Returns the index that was removed, or nil if the card wasn't there. Removing the last card
    /// does NOT end the sitting (§4.3) — an empty sitting is a state, not a dismissal.
    @discardableResult
    public mutating func remove(cardID: UUID) -> Int? {
        guard let index = dishes.firstIndex(where: { $0.id == cardID }) else { return nil }
        dishes.remove(at: index)
        return index
    }

    @discardableResult
    public mutating func remove(atOffsets offsets: IndexSet) -> [UUID] {
        let removed = offsets.map { dishes[$0].id }
        dishes.remove(atOffsets: offsets)
        return removed
    }

    // MARK: - Editing

    public func index(of cardID: UUID) -> Int? {
        dishes.firstIndex(where: { $0.id == cardID })
    }

    public subscript(cardID: UUID) -> SittingDish? {
        dishes.first(where: { $0.id == cardID })
    }

    /// The one mutation door. Everything (rating, note, photo state) goes through it so a card that
    /// is no longer on the canvas — deleted while its photo was still uploading — silently drops its
    /// late update instead of resurrecting.
    public mutating func update(cardID: UUID, _ mutate: (inout SittingDish) -> Void) {
        guard let index = index(of: cardID) else { return }
        mutate(&dishes[index])
    }

    public mutating func setScore(_ score: Rating?, for cardID: UUID) {
        update(cardID: cardID) { $0.score = score }
    }

    public mutating func setNote(_ note: String, for cardID: UUID) {
        update(cardID: cardID) { $0.note = note }
    }

    public mutating func setPhoto(_ photo: SittingPhoto?, for cardID: UUID) {
        update(cardID: cardID) { $0.photo = photo }
    }

    public mutating func setPhotoUploadState(_ state: PhotoUploadState, for cardID: UUID) {
        update(cardID: cardID) { $0.photo?.uploadState = state }
    }

    // MARK: - Post gate (§4.3)

    /// "Post enabled when count >= 1 && all cards score >= 0.5." An unrated card doesn't disable the
    /// button — tapping it scrolls to and wiggles the offender (§2.4), which teaches; a dead button
    /// doesn't.
    public var isPostable: Bool { !dishes.isEmpty && dishes.allSatisfy(\.isRated) }

    /// The first card that would block a post, for the scroll-and-wiggle.
    public var firstUnratedCardID: UUID? { dishes.first(where: { !$0.isRated })?.id }

    public var isEmpty: Bool { dishes.isEmpty }

    /// §7 dismissal guard: is there anything a person would be sad to lose?
    public var hasContent: Bool { dishes.contains(where: \.hasContent) }

    /// §5.1: a photo still uploading turns Post into "Uploading photo…" rather than blocking it.
    public var hasUploadInFlight: Bool {
        dishes.contains { $0.photo?.uploadState.isInFlight == true }
    }

    public var hasNote: Bool { dishes.contains { $0.trimmedNote != nil } }
    public var hasPhoto: Bool { dishes.contains { $0.photo != nil } }

    /// §4.2: "One Post for all — button pluralises."
    public var postButtonTitle: String {
        dishes.count <= 1 ? "Post" : "Post \(dishes.count) dishes"
    }

    /// Seconds from opening the sheet to the tap — `log_posted(seconds_from_open)`.
    public func secondsFromOpen(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt).rounded()))
    }
}

import Foundation

/// One label an on-device image classifier gave a photo, and how sure it was (0…1).
public struct PhotoLabel: Equatable, Sendable {
    public let identifier: String
    public let confidence: Float

    public init(_ identifier: String, _ confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// **Is this a photo of something eaten or drunk?** The rule `Suggestions` offers photos by.
///
/// The labels come from Vision's `VNClassifyImageRequest`, on the device — nothing about a photo
/// ever leaves it. That taxonomy is a hierarchy (1,303 identifiers on iOS 26): a dish fires its own
/// label *and* its parents, so a burger is `hamburger` and `meat` and `food`, and a latte is
/// `coffee` and `drink`. The rule therefore reads the parents plus the few drink and dessert labels
/// that can stand without them.
///
/// **Threshold 0.3**, from Vision's own scores on the eight prototype photos (a burger, cake, penne,
/// pizza, prawn spaghetti, ragù, sushi, tiramisu): `food` came back between 0.44 (ragù, shot in its
/// pan, where `pan`/`cookware` outscored it) and 0.98 (tiramisu). Landscapes scored no food label at
/// all. 0.3 keeps the weakest real dish with margin and still asks the classifier to mean it.
public enum FoodPhotoRule {
    public static let threshold: Float = 0.3

    /// The labels that make a photo a meal. Parents first; the rest are drinks and sweets the
    /// taxonomy does not always roll up under `food`.
    public static let identifiers: Set<String> = [
        "food", "drink", "dessert", "baked_goods", "frozen_dessert",
        "coffee", "tea_drink", "bubble_tea", "cocktail", "beer", "wine", "juice"
    ]

    /// True when any of the photo's labels at or above ``threshold`` is a food or drink label.
    public static func isFood(_ labels: [PhotoLabel]) -> Bool {
        labels.contains { $0.confidence >= threshold && identifiers.contains($0.identifier) }
    }
}

/// **The camera roll, reduced to meals.** Classifies each photo once and remembers the verdict by
/// its asset identifier, so a second visit to `Suggestions` — or the journal's badge on the next
/// launch — costs a dictionary lookup rather than a pass through Vision.
///
/// An actor, so the classifying happens off the main actor and two callers asking at once (the
/// badge and the screen) share one cache. The classifier is injected: the app hands it Vision, the
/// tests hand it a table.
public actor FoodPhotoFilter {
    /// The labels for one asset, or `nil` if it could not be read right now (no local thumbnail, a
    /// decode failure). A `nil` is not remembered — it is asked again next time.
    public typealias Classify = @Sendable (String) async -> [PhotoLabel]?

    private let classify: Classify
    private var verdicts: [String: Bool]
    /// Classifications under way. The actor is re-entrant across the classifier's await, so two
    /// callers at once (the badge and the screen) would otherwise both send the same photo through.
    private var inFlight: [String: Task<[PhotoLabel]?, Never>] = [:]

    public init(verdicts: [String: Bool] = [:], classify: @escaping Classify) {
        self.verdicts = verdicts
        self.classify = classify
    }

    /// What was learnt so far, for the caller to keep between launches.
    public var knownVerdicts: [String: Bool] { verdicts }

    /// The items that are food, in the order given. Anything that cannot be classified is left out:
    /// `Suggestions` offers meals, and "don't know" is not one.
    ///
    /// **Stops when its task is cancelled** — leaving `Suggestions` must not keep Vision running
    /// through the rest of the camera roll. It stops *between* photos: every verdict already learnt
    /// stays in the cache, and the result says it is incomplete. `progress` hears the food found so
    /// far each time another photo is confirmed.
    public func filter(
        _ items: [PhotoSuggestionItem],
        progress: (@Sendable (FoodPhotoResult) -> Void)? = nil
    ) async -> FoodPhotoResult {
        var kept: [PhotoSuggestionItem] = []
        var classified = 0
        var looked = 0
        for item in items {
            if Task.isCancelled {
                return FoodPhotoResult(kept: kept, dropped: looked - kept.count,
                                       newlyClassified: classified, isComplete: false)
            }
            let verdict: Bool?
            if let known = verdicts[item.id] {
                verdict = known
            } else if let labels = await labels(for: item.id) {
                let isFood = FoodPhotoRule.isFood(labels)
                verdicts[item.id] = isFood
                classified += 1
                verdict = isFood
            } else {
                verdict = nil
            }
            looked += 1
            if verdict == true {
                kept.append(item)
                progress?(FoodPhotoResult(kept: kept, dropped: looked - kept.count,
                                          newlyClassified: classified, isComplete: false))
            }
        }
        return FoodPhotoResult(kept: kept, dropped: items.count - kept.count, newlyClassified: classified)
    }

    /// **The same pass, as it happens**, newest photo first: one snapshot each time another photo
    /// is confirmed as food, then a last one with `isComplete` (or not, if it was cut short).
    ///
    /// Ending the iteration — the screen going away — cancels the pass between photos.
    public nonisolated func progressively(_ items: [PhotoSuggestionItem]) -> AsyncStream<FoodPhotoResult> {
        let newestFirst = items.sorted { $0.createdAt > $1.createdAt }
        return AsyncStream { continuation in
            let pass = Task {
                let result = await self.filter(newestFirst) { continuation.yield($0) }
                continuation.yield(result)
                continuation.finish()
            }
            continuation.onTermination = { _ in pass.cancel() }
        }
    }

    private func labels(for id: String) async -> [PhotoLabel]? {
        if let running = inFlight[id] { return await running.value }
        let classify = classify
        let task = Task { await classify(id) }
        inFlight[id] = task
        let labels = await task.value
        inFlight[id] = nil
        return labels
    }
}

/// One pass of ``FoodPhotoFilter``.
public struct FoodPhotoResult: Equatable, Sendable {
    public let kept: [PhotoSuggestionItem]
    /// Photos in the window that were not offered: not food, or not readable.
    public let dropped: Int
    /// How many went through the classifier this time (the rest were already known).
    public let newlyClassified: Int
    /// False for a snapshot taken mid-pass, and for a pass that was cancelled.
    public let isComplete: Bool

    public init(kept: [PhotoSuggestionItem], dropped: Int, newlyClassified: Int, isComplete: Bool = true) {
        self.kept = kept
        self.dropped = dropped
        self.newlyClassified = newlyClassified
        self.isComplete = isComplete
    }
}

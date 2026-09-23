import Foundation

/// Something that holds a bookmark for a dish and has to agree with every other thing that does.
@MainActor
public protocol SavedDishObserving: AnyObject {
    func savedDishChanged(dishID: UUID, isSaved: Bool)
}

/// **One dish, one answer, everywhere it is on screen.**
///
/// A save is a fact about a *dish*, not about the row it was tapped on — and by the time somebody
/// taps one, the same dish can be on the feed behind them, on the profile they came through, on the
/// entry page they are looking at, and on the shelf. Propagating that by hand means a list of stores
/// maintained at every call site, and the one that gets forgotten is a stale bookmark the reader
/// sees when they tap Back (QA found exactly that: feed → profile → entry → toggle → back).
///
/// So nothing is hand-wired. Everything that draws a bookmark registers here and is told.
///
/// Observers are held **weakly** and pruned as they go: a profile popped off the stack unregisters
/// by being deallocated, which is the only deregistration that cannot be forgotten either. Nothing
/// re-broadcasts — a listener writes its own state and stops, so there is no loop to break.
@MainActor
public final class SavedDishBroadcast {
    private var observers: [WeakObserver] = []

    public init() {}

    public func add(_ observer: any SavedDishObserving) {
        prune()
        guard observers.contains(where: { $0.value === observer }) == false else { return }
        observers.append(WeakObserver(value: observer))
    }

    /// The dish changed. Called with the optimistic value the moment a bookmark is tapped, and
    /// again with the old one if the server refuses.
    public func send(dishID: UUID, isSaved: Bool) {
        prune()
        for observer in observers {
            observer.value?.savedDishChanged(dishID: dishID, isSaved: isSaved)
        }
    }

    /// How many are listening. Tests assert that a store that has gone away has stopped.
    public var observerCount: Int {
        prune()
        return observers.count
    }

    private func prune() {
        observers.removeAll { $0.value == nil }
    }

    private struct WeakObserver {
        weak var value: (any SavedDishObserving)?
    }
}

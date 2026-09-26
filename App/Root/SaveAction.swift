import AteKit
import SwiftUI

/// **The save, wherever it is made.** The feed's bookmark, a profile's, the one on someone else's
/// entry page and the unsave on the Saved shelf are the same action and must behave identically
/// (AGENTS.md rule 2) — so there is one of it, made once at the shell and handed down.
///
/// What "identically" means here:
/// 1. the bookmark flips **before** the RPC, and is put back if the RPC refuses — a save is one tap
///    on a moving list, and a round trip is a visible stutter;
/// 2. it flips **everywhere that dish is on screen**, through ``SavedDishBroadcast``: the feed, the
///    profile that was opened from it, the entry page on top of both. Nothing is hand-wired, so
///    nothing can be forgotten;
/// 3. it is **felt** — one light impact, the moment it flips;
/// 4. `save_toggled` is emitted at the tap, with the surface it happened on, because the number we
///    act on is how often people save and not how often the network agreed;
/// 5. the Saved shelf is told it is stale, so the dish is there the next time it is looked at;
/// 6. somebody browsing signed out is asked to sign in instead (``SessionGate``), and nothing flips.
///
/// A class, not a value: it holds which dishes are mid-flight, and two taps on one bookmark must
/// meet the same set.
@MainActor
final class SaveAction {
    private let saves: any DishSaving
    private let analytics: AnalyticsRecorder
    /// The shelf to invalidate. It reloads when it is next looked at, not while it is not.
    private let shelf: SavedDishesStore
    private let broadcast: SavedDishBroadcast
    /// Asked before every save. Nil means nobody can be signed out here (previews).
    private let gate: SessionGate?
    /// Dishes with a call in the air. A second tap while one is in flight is dropped rather than
    /// queued: two RPCs racing can land in the other order and leave the bookmark disagreeing with
    /// the server, which is the one outcome an optimistic write must never produce.
    private var inFlight: Set<UUID> = []

    init(
        saves: any DishSaving,
        analytics: @escaping AnalyticsRecorder,
        shelf: SavedDishesStore,
        broadcast: SavedDishBroadcast,
        gate: SessionGate? = nil
    ) {
        self.saves = saves
        self.analytics = analytics
        self.shelf = shelf
        self.broadcast = broadcast
        self.gate = gate
    }

    /// A save is a write: a browser is asked to sign in, and the bookmark stays as it was.
    private var mayWrite: Bool { gate?.permitsWrite(.save) ?? true }

    /// One dish's bookmark.
    func toggle(dishID: UUID, entryID: UUID?, isSaved: Bool, source: SaveSource) async {
        guard mayWrite else { return }
        guard inFlight.insert(dishID).inserted else { return }
        defer { inFlight.remove(dishID) }

        let next = isSaved == false
        broadcast.send(dishID: dishID, isSaved: next)
        AteHaptics.save()
        analytics(SocialEvents.saveToggled(source: source, isSaved: next))
        do {
            if next {
                try await saves.save(dishID: dishID, sourceEntryID: entryID)
            } else {
                try await saves.unsave(dishID: dishID)
            }
            shelf.invalidate()
        } catch {
            // The server had the last word. Put the bookmark back rather than leaving a save that
            // did not happen looking like one that did.
            broadcast.send(dishID: dishID, isSaved: isSaved)
        }
    }

    /// The unsave on the Saved shelf, where the bookmark is the only reason the row exists — so the
    /// store removes it, and only a refusal-free round trip is told to the rest of the app.
    /// Returns whether it landed, so a second list showing the same shelf (Search's Saved segment)
    /// can put its row back on a refusal exactly as the shelf does.
    @discardableResult
    func unsaveFromShelf(_ dish: SavedDish, source: SaveSource = .savedList) async -> Bool {
        guard inFlight.insert(dish.dishID).inserted else { return false }
        defer { inFlight.remove(dish.dishID) }

        AteHaptics.save()
        guard await shelf.unsave(dish) else { return false }
        // The Undo pill belongs to the shelf; an unsave made elsewhere offers none.
        if source != .savedList { shelf.expireUndo(for: dish) }
        analytics(SocialEvents.saveToggled(source: source, isSaved: false))
        broadcast.send(dishID: dish.dishID, isSaved: false)
        return true
    }

    /// **Undo**, on the Saved shelf's pill: the dish the shelf just let go of goes back on it, saved
    /// again with the entry it was first saved off, and every list that draws it hears so.
    func undoUnsaveFromShelf() async {
        guard let dish = shelf.undoable, inFlight.insert(dish.dishID).inserted else { return }
        defer { inFlight.remove(dish.dishID) }
        AteHaptics.save()
        analytics(RecoveryEvents.unsaveUndone())
        guard await shelf.undoUnsave() else { return }
        broadcast.send(dishID: dish.dishID, isSaved: true)
    }

    /// "Save this place" — every line of one entry, provenance = that entry
    /// (`save_entry_dishes`). Returns whether it landed.
    @discardableResult
    func saveEveryDish(entryID: UUID, dishIDs: [UUID], source: SaveSource) async -> Bool {
        guard mayWrite else { return false }
        let claimed = dishIDs.filter { inFlight.insert($0).inserted }
        defer { claimed.forEach { inFlight.remove($0) } }
        guard claimed.isEmpty == false else { return false }

        claimed.forEach { broadcast.send(dishID: $0, isSaved: true) }
        AteHaptics.save()
        analytics(SocialEvents.saveToggled(source: source, isSaved: true))
        do {
            _ = try await saves.saveEntryDishes(entryID: entryID)
            shelf.invalidate()
            return true
        } catch {
            // One RPC for the whole visit, so one rollback for the whole visit.
            claimed.forEach { broadcast.send(dishID: $0, isSaved: false) }
            return false
        }
    }

    /// The other half of the entry page's bookmark: an entry whose every line is already saved
    /// un-saves all of them. There is no `unsave_entry_dishes` in the contract — unsaving is per
    /// dish, so this is that call, once per line, and **each line is rolled back on its own**: a
    /// failure on the third dish must not put the first two back on a shelf they have left.
    func unsaveEveryDish(dishIDs: [UUID], source: SaveSource) async {
        guard mayWrite else { return }
        let claimed = dishIDs.filter { inFlight.insert($0).inserted }
        defer { claimed.forEach { inFlight.remove($0) } }
        guard claimed.isEmpty == false else { return }

        claimed.forEach { broadcast.send(dishID: $0, isSaved: false) }
        AteHaptics.save()
        analytics(SocialEvents.saveToggled(source: source, isSaved: false))
        var anyLanded = false
        for dishID in claimed {
            do {
                try await saves.unsave(dishID: dishID)
                anyLanded = true
            } catch {
                broadcast.send(dishID: dishID, isSaved: true)
            }
        }
        if anyLanded { shelf.invalidate() }
    }
}

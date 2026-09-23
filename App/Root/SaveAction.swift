import AteKit
import SwiftUI

/// **The save, wherever it is made.** The feed's bookmark, a profile's, the one on someone else's
/// entry page and the unsave on the Saved shelf are the same action and must behave identically
/// (AGENTS.md rule 2) — so there is one of it.
///
/// What "identically" means here:
/// 1. the bookmark flips **before** the RPC, and is put back if the RPC refuses — a save is one tap
///    on a moving list, and a round trip is a visible stutter;
/// 2. it is **felt** — one light impact, the moment it flips;
/// 3. `save_toggled` is emitted at the tap, with the surface it happened on, because the number we
///    act on is how often people save and not how often the network agreed;
/// 4. the Saved shelf is told it is stale, so the dish is there the next time it is looked at.
@MainActor
struct SaveAction {
    let saves: any DishSaving
    let analytics: AnalyticsRecorder
    /// The shelf to invalidate. It reloads when it is next looked at, not while it is not.
    let shelf: SavedDishesStore

    /// - Parameters:
    ///   - apply: writes the optimistic state wherever it is held — usually one or more
    ///     ``EntryListStore``s. Called once with the new state, and again with the old one if the
    ///     server refuses.
    func toggle(
        dishID: UUID,
        entryID: UUID?,
        isSaved: Bool,
        source: SaveSource,
        apply: (Bool) -> Void
    ) async {
        let next = isSaved == false
        apply(next)
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
            apply(isSaved)
        }
    }

    /// "Save this place" — every line of one entry, provenance = that entry
    /// (`save_entry_dishes`). Returns whether it landed.
    @discardableResult
    func saveEveryDish(entryID: UUID, source: SaveSource, apply: (Bool) -> Void) async -> Bool {
        apply(true)
        AteHaptics.save()
        analytics(SocialEvents.saveToggled(source: source, isSaved: true))
        do {
            _ = try await saves.saveEntryDishes(entryID: entryID)
            shelf.invalidate()
            return true
        } catch {
            apply(false)
            return false
        }
    }

    /// The other half of the entry page's bookmark: an entry whose every line is already saved
    /// un-saves all of them. There is no `unsave_entry_dishes` in the contract — unsaving is per
    /// dish, so this is that call, once per line.
    func unsaveEveryDish(dishIDs: [UUID], source: SaveSource, apply: (Bool) -> Void) async {
        apply(false)
        AteHaptics.save()
        analytics(SocialEvents.saveToggled(source: source, isSaved: false))
        do {
            for dishID in dishIDs {
                try await saves.unsave(dishID: dishID)
            }
            shelf.invalidate()
        } catch {
            apply(true)
        }
    }
}

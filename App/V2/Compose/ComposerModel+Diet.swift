import AteKit
import Foundation

/// **The author's diet on the Diet key** (`design/rebuild/diet.html`): the codes it stamps on a new
/// entry's dishes, lit for the dish at the caret and turned off one dish at a time — or, on an edit,
/// the codes the diet put on each saved line, which the author can turn off there. Nothing about it
/// goes into the words.
extension ComposerModel {
    /// The codes lit in the Diet key's unfold for the dish at the caret: its chips in the words, and
    /// the ones its diet gives it.
    var litCodes: [DietTag] {
        let lit = Set(composition.dishTags(atDisplayOffset: caret))
            .union(diet.lit(in: composition, atDisplayOffset: caret))
        return DietTag.allCases.filter { lit.contains($0) }
    }

    /// The Diet key's codes in the order they unfold (`diet-more.html`): the author's own diet first,
    /// so turning one off for a dish is one tap even though ten codes scroll; then the rest.
    var dietKeyOrder: [DietTag] {
        let own = DietTag.pickingOrder.filter(diet.diet.contains)
        return own + DietTag.pickingOrder.filter { own.contains($0) == false }
    }

    /// A code the author's diet puts on the dish at the caret turns off for it, or back on. `nil` when
    /// the code is not the diet's for this dish: the key then puts a chip in, as it always did.
    func toggleDiet(_ tag: DietTag) -> AnalyticsEvent? {
        guard let toggled = diet.toggle(tag, in: composition, atDisplayOffset: caret) else { return nil }
        switch toggled {
        case .off(let tag): return DietEvents.turnedOff(tag, isEdit: editing != nil)
        case .on(let tag): return DietEvents.turnedOn(tag, isEdit: editing != nil)
        }
    }
}

import AteKit
import SwiftUI

/// **The 6 in the composer**: how many are left for the slider's lock (two in any two months,
/// 0091), and what posting one changes — the filters offer it, and "You found the 6" is owed.
extension V2ComposerWrite {
    /// A 6 in these words: the filters offer the 6 from now on, and someone never told about it is
    /// told once the composer is down (``SixFoundScreen``).
    func noteTheSix() {
        guard model.composition.sixTokens.isEmpty == false else { return }
        let me = services.api.currentUserID
        services.preferences.gaveSix(me)
        if services.preferences.owesSixFound(me) { app.owesSixFound = true }
    }

    /// The 6s left, for the slider's lock — once, as the composer opens; an edit counts its own back.
    func readSixAllowance() async {
        sixAllowance = try? await services.entries.sixAllowance(editing: model.editing?.id)
    }
}

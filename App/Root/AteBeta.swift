import AteKit

/// **The beta layout** (Eamon, 11 Oct): while there are too few receipts for the full designs to
/// mean anything, the Feed is every receipt, newest first, from everywhere, and Saved takes dishes
/// you add yourself. The full designs stay built behind this one switch; turn it off (here, or with
/// `-ate-full-edition` on a Debug drive) and they come back exactly as they were.
enum AteBeta {
    /// The switch. `true` for every build until the Feed has the density its edition needs.
    private static let isShipping = true

    static var isOn: Bool {
        #if DEBUG
        if DebugLaunch.isOn(.fullEdition) { return false }
        #endif
        return isShipping
    }
}

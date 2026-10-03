import SwiftUI

/// **The segmented control** — the one the design has: a pill for each choice inside a
/// field-coloured pill, the current one raised, every title in Bricolage (the system's segmented
/// `Picker` draws in SF and cannot be given the app's type). Journal | Saved, the filter sheet's
/// Sort, Search's scopes. Fills its row, its choices sharing the width equally.
///
/// The existing ``AteSegments``, with the row-filling dress decided once.
struct AteSegmentedControl<Value: Hashable>: View {
    let options: [AteSegment<Value>]
    @Binding var selection: Value
    /// Each choice's identifier is this, a dot, and its title in lower case.
    var identifier: String?

    var body: some View {
        AteSegments(options: options, selection: $selection, hugs: false, identifier: identifier)
    }
}

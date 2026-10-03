import SwiftUI

/// **The scope switch** — Search's one equal-width segment (Dishes, Places, People, Saved) with the
/// one filter disc at its end (round 5): nothing on the row moves when the scope changes. The disc is
/// glass, inked while a filter is on, and muted where no filter applies (People) without leaving its
/// place. The segment is the kit's ``AteSegmentedControl`` (Bricolage, equal widths).
struct AteScopeSwitch<Value: Hashable>: View {
    let options: [AteSegment<Value>]
    @Binding var selection: Value
    /// Something is filtered: the disc turns ink.
    let isFilterOn: Bool
    /// Off where no filter narrows the scope: muted, and the tap does nothing.
    var isFilterAvailable = true
    var identifier = "search.scope"
    let onFilter: () -> Void

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            AteSegmentedControl(options: options, selection: $selection, identifier: identifier)
            AteGlassDisc(
                icon: .listFilter,
                label: "Filter",
                role: isFilterOn && isFilterAvailable ? .primary : .plain,
                isEnabled: isFilterAvailable,
                identifier: "\(identifier).filter",
                action: onFilter
            )
        }
    }
}

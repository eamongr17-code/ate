import AteKit
import SwiftUI

/// **Choose your cravings** (round 8) — the picker behind the Feed's cravings row: every craving
/// `craving_options()` offers, as the house's toggle pills (the city picker's own, ink when on), in
/// their groups — dishes, cuisines, moods — with no label over a group. Nothing is saved until Done,
/// which replaces the whole set (`set_cravings`); a swipe down leaves it as it was.
///
/// Not drawn on the approved canvas, so built from the vocabulary it already has: ``AteSheet`` (title,
/// content, one ink pill) and ``AteFilterChoice``.
struct CravingsSheet: View {
    let store: FeedEditionStore
    let onDone: ([Craving]) -> Void

    @State private var picker: CravingPicker?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(title: "Cravings", primary: ("Done", done), isLoading: store.hasLoadedOptions == false) {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                if let picker {
                    ForEach(picker.groups, id: \.group) { group in
                        AteFlow(spacing: AteMetrics.snug) {
                            ForEach(group.options) { option in
                                AteFilterChoice(
                                    title: option.craving.title, isOn: picker.isOn(option), textStyle: .chipLabel
                                ) {
                                    AteHaptics.key()
                                    self.picker?.toggle(option)
                                }
                                .accessibilityIdentifier("cravings.\(option.id)")
                            }
                        }
                    }
                } else {
                    AteFlow(spacing: AteMetrics.snug) {
                        ForEach([88, 64, 112, 72, 96], id: \.self) { width in
                            AteSkeletonBar(width: CGFloat(width), height: AteFilterPill.height, palette: .surface)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.loose)
        }
        .task {
            await store.loadOptionsIfNeeded()
            if picker == nil, store.hasLoadedOptions {
                picker = CravingPicker(options: store.options, selected: store.cravings)
            }
        }
        .onChange(of: store.hasLoadedOptions) { _, loaded in
            guard loaded, picker == nil else { return }
            picker = CravingPicker(options: store.options, selected: store.cravings)
        }
    }

    private func done() {
        if let picker { onDone(picker.selection) }
        dismiss()
    }
}

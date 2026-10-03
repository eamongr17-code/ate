import AteKit
import SwiftUI

/// **Cravings** — the heart's sheet (and the "Choose your cravings" row's): every craving
/// `craving_options()` offers as toggle pills, dish styles then cuisines then moods, with no label
/// over a group. Nothing is saved until the ink pill — "Follow 4 cravings" — which replaces the whole
/// set (`set_cravings`); close leaves it as it was.
struct FeedCravingsSheet: View {
    let store: FeedEditionStore
    let onCommit: ([Craving]) -> Void

    @State private var picker: CravingPicker?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(title: "Cravings", commit: commit) {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                if let picker {
                    ForEach(picker.groups, id: \.group) { group in
                        AteTogglePillFlow {
                            ForEach(group.options) { option in
                                AteTogglePill(
                                    title: option.craving.title,
                                    isOn: picker.isOn(option),
                                    identifier: "cravings.\(option.id)"
                                ) {
                                    AteHaptics.key()
                                    self.picker?.toggle(option)
                                }
                            }
                        }
                    }
                } else {
                    loading
                }
            }
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

    /// The live count; with none picked it still commits — unfollowing everything is a choice.
    private var commit: AteSheetCommit {
        let count = picker?.selection.count ?? store.cravings.count
        let title = switch count {
        case 0: "Follow no cravings"
        case 1: "Follow 1 craving"
        default: "Follow \(count) cravings"
        }
        return AteSheetCommit(title: title, isEnabled: picker != nil) {
            if let picker { onCommit(picker.selection) }
            dismiss()
        }
    }

    /// Skeletons of the pills while the options are read.
    private var loading: some View {
        AteTogglePillFlow {
            ForEach(FeedCravingsSheetMetrics.skeletonWidths, id: \.self) { width in
                AteSkeletonBar(width: width, height: AteTogglePillMetrics.height, palette: .surface)
            }
        }
        .ateBreathing()
        .accessibilityHidden(true)
    }
}

enum FeedCravingsSheetMetrics {
    static let skeletonWidths: [CGFloat] = [88, 64, 112, 72, 96, 80, 120]
}

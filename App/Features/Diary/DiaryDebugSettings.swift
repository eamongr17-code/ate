import SwiftUI

/// §11's one open question, settled on device rather than in argument.
///
/// **A** puts the composer at the top of the list, where it scrolls away — the tab bar's `+` is
/// already permanently in the thumb zone, so a second permanent button is a duplicate that costs a
/// row of the record forever. **B** pins it with `safeAreaInset(edge: .top)` — always reachable, at
/// the price of never getting out of the way.
///
/// Same action, same `log_cta_tapped(from: diary_composer)` in both, so the toggle changes placement
/// and nothing else, and the funnel can be read across the two.
///
/// Debug-only: Release is hard-wired to A, so the switch cannot exist in a shipped app.
enum DiaryDebugSettings {
    static let composerPlacementKey = "debug.diary.composerPlacement"

    static var composerPlacement: DiaryComposerPlacement {
        #if DEBUG
        UserDefaults.standard.string(forKey: composerPlacementKey)
            .flatMap(DiaryComposerPlacement.init(rawValue:)) ?? .topOfList
        #else
        .topOfList
        #endif
    }
}

enum DiaryComposerPlacement: String, CaseIterable, Identifiable {
    /// A — first row of the list, scrolls away. The default.
    case topOfList
    /// B — pinned above the list via `safeAreaInset(edge: .top)`.
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topOfList: "Composer: top of list"
        case .pinned: "Composer: pinned"
        }
    }
}

/// The switch itself, as a toolbar menu on the diary. Compiled out of Release entirely.
struct DiaryDebugMenu: View {
    @AppStorage(DiaryDebugSettings.composerPlacementKey)
    private var raw = DiaryComposerPlacement.topOfList.rawValue

    var body: some View {
        #if DEBUG
        menu
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    private var menu: some View {
        Menu {
            Picker("Composer placement", selection: $raw) {
                ForEach(DiaryComposerPlacement.allCases) { placement in
                    Text(placement.title).tag(placement.rawValue)
                }
            }
        } label: {
            Image(systemName: "ladybug")
        }
        .accessibilityLabel("Debug options")
    }
    #endif
}

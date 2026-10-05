import AteKit
import SwiftUI

/// **"Who were you with?"** (`ate-with.html` 1b) — the place sheet's twin: close top left, the title,
/// the search pill. Before typing, the people tagged most recently; typing searches every handle on
/// Ate. Rows toggle a check and gather as ink chips; the foot pill counts them ("Add 2 people"), six
/// at most. Nobody blocked either way ever appears (the server leaves them out). No invite row in
/// this release.
struct ComposerWithSheet: View {
    let service: any CompanionTagging
    let initial: [CompanionPerson]
    let analytics: AnalyticsRecorder
    let onCommit: ([CompanionPerson]) -> Void

    @State private var store: CompanionPickerStore
    @Environment(\.dismiss) private var dismiss

    init(
        service: any CompanionTagging,
        initial: [CompanionPerson],
        analytics: @escaping AnalyticsRecorder,
        onCommit: @escaping ([CompanionPerson]) -> Void
    ) {
        self.service = service
        self.initial = initial
        self.analytics = analytics
        self.onCommit = onCommit
        _store = State(initialValue: CompanionPickerStore(service: service, selected: initial))
    }

    var body: some View {
        @Bindable var store = store
        AteSheetScaffold(
            title: "Who were you with?",
            searchPrompt: "Search handles",
            searchText: $store.query,
            commit: AteSheetCommit(title: store.commitTitle, isEnabled: store.canCommit) {
                onCommit(store.selected)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                if store.selected.isEmpty == false {
                    AteFilterChipRow(
                        chips: store.selected.map {
                            AteFilterChipRow.Chip(id: $0.userID.uuidString, title: "@\($0.handle)")
                        },
                        onClear: { chip in
                            guard let person = store.selected.first(where: { $0.userID.uuidString == chip.id }) else {
                                return
                            }
                            AteHaptics.key()
                            store.remove(person)
                        }
                    )
                    // The chip row lays its own list gutter; in a sheet the body already has one.
                    .padding(.horizontal, -AteMetrics.listGutter)
                    .accessibilityIdentifier("with.chips")
                }
                list
            }
        }
        .task { await store.loadRecents() }
        .onAppear { analytics(CompanionEvents.pickerOpened()) }
    }

    @ViewBuilder
    private var list: some View {
        if store.phase == .loading && store.rows.isEmpty {
            AteSheetSkeletonRows(count: ComposerWithSheetMetrics.skeletonRows)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, person in
                    AtePersonPickRow(
                        person: AteWithPerson(id: person.userID, handle: person.handle),
                        name: person.name,
                        isSelected: store.isSelected(person),
                        isFirst: index == 0
                    ) {
                        toggle(person)
                    }
                    .onAppear {
                        if index == store.rows.count - 1 { Task { await store.loadMore() } }
                    }
                }
            }
        }
    }

    /// A tap ticks or unticks; a seventh is refused under the finger, never in words.
    private func toggle(_ person: CompanionPerson) {
        if store.toggle(person) {
            AteHaptics.key()
        } else {
            AteHaptics.refused()
        }
    }
}

enum ComposerWithSheetMetrics {
    /// The breathing rows while the recents load.
    static let skeletonRows = 4
}

extension View {
    /// The composer's people sheet, over whatever presents it.
    func v2WithSheet(
        isPresented: Binding<Bool>,
        service: any CompanionTagging,
        initial: @escaping @MainActor () -> [CompanionPerson],
        analytics: @escaping AnalyticsRecorder,
        onCommit: @escaping ([CompanionPerson]) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            ComposerWithSheet(service: service, initial: initial(), analytics: analytics, onCommit: onCommit)
        }
    }
}

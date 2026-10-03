import AteKit
import SwiftUI

/// **Appearance** — System, Light, Dark, in the system's grouped list; the chosen one carries the
/// check. (Settings' own row is a menu on the same choice; this page is what its route opens.)
struct V2AppearancePage: View {
    let model: SettingsModel

    var body: some View {
        List {
            Section {
                ForEach(AteAppearance.allCases, id: \.self) { appearance in
                    AteGroupedRow(title: appearance.title, showsChevron: false) {
                        model.appearance = appearance
                    } trailing: {
                        if model.appearance == appearance {
                            AteIcon.check.view(size: AteMetrics.settingsCheck)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .accessibilityAddTraits(model.appearance == appearance ? .isSelected : [])
                }
            }
        }
        .ateGroupedList()
        .ateInlineTitle("Appearance")
    }
}

/// **How Ate uses AI** — one page of plain words, in the voice the app uses for words. The words are
/// the current build's (``AICopy``, a copy proposal Eamon has still to approve).
struct V2AIPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                ForEach(AICopy.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .ateText(.proseLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.regular)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ateGround()
        .ateInlineTitle("How Ate uses AI")
    }
}

/// **Blocked people** — who, and one way to undo it: Unblock in each row's swipe. Nobody blocked
/// draws nothing: an empty list is the state, and a line saying so would be helper copy.
struct V2BlockedPeoplePage: View {
    @State var store: BlockedPeopleStore

    var body: some View {
        List {
            if store.people.isEmpty == false {
                Section {
                    ForEach(store.people) { person in
                        AteGroupedRow(title: person.title, showsChevron: false, identifier: "blocked.person") {}
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Unblock") {
                                    Task { await store.unblock(person) }
                                }
                                .accessibilityIdentifier("blocked.unblock")
                            }
                            .task { if person.id == store.people.last?.id { await store.loadMore() } }
                    }
                }
            }
        }
        .ateGroupedList()
        .ateInlineTitle("Blocked people")
        .task { await store.loadIfNeeded() }
        .refreshable { await store.refresh() }
    }
}

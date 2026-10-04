import AteKit
import SwiftUI

/// **The three pages Settings opens.** None of them is drawn in `design/v1` — the artboard stops at
/// the row — so each is built from the vocabulary Settings itself uses: the same header (the system's
/// glass back button, the name at `.h` 24), the same 56pt rows ruled at the top, the same gutter. A
/// page pushed from a list of rows is a list of rows.

/// A pushed settings page: the header, then its content from `padding:14px 20px 0`.
struct AteSettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.top, AteSettingsPage.contentTop)
                .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // The glass back button, and the page's name after it (round 5: the app's own top bar).
        .ateNavigationBar(leading: { AteNavigationTitle(title: title) })
        .ateGround()
    }

    /// `padding:14px 20px 0` under the header.
    static var contentTop: CGFloat { 14 }
}

/// **Appearance** — System, Light, Dark. The chosen one carries the check the handle field uses;
/// the others carry nothing.
struct AppearanceScreen: View {
    let model: SettingsModel
    var body: some View {
        AteSettingsPage(title: "Appearance") {
            VStack(spacing: 0) {
                ForEach(AteAppearance.allCases, id: \.self) { appearance in
                    AteSettingsRow(title: appearance.title, showsChevron: false) {
                        if model.appearance == appearance {
                            AteIcon.check.view(size: AteMetrics.settingsCheck)
                                .accessibilityLabel("Selected")
                        }
                    } action: {
                        model.appearance = appearance
                    }
                    .accessibilityAddTraits(model.appearance == appearance ? .isSelected : [])
                }
            }
        }
    }
}

/// **How Ate uses AI** — one page of plain words, in the voice the app uses for words: Newsreader.
struct AIScreen: View {
    var body: some View {
        AteSettingsPage(title: "How Ate uses AI") {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                ForEach(AICopy.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .ateText(.proseLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, AteMetrics.snug)
        }
    }
}

/// **Blocked people** — who, and one way to undo it.
///
/// Nobody blocked draws nothing under the header: an empty list is the state, and a line saying so
/// would be helper copy (design rule 1).
struct BlockedPeopleScreen: View {
    @State var store: BlockedPeopleStore

    var body: some View {
        AteSettingsPage(title: "Blocked people") {
            LazyVStack(spacing: 0) {
                ForEach(store.people) { person in
                    AteSettingsRow(title: person.title, showsChevron: false) {
                        Button("Unblock") {
                            Task { await store.unblock(person) }
                        }
                        .buttonStyle(.plain)
                        .ateText(.control)
                        .frame(minHeight: AteMetrics.hit)
                        .contentShape(.rect)
                        .accessibilityIdentifier("blocked.unblock")
                    }
                    .task { if person.id == store.people.last?.id { await store.loadMore() } }
                }
            }
        }
        .task { await store.loadIfNeeded() }
        .refreshable { await store.refresh() }
    }
}

#if DEBUG
#Preview("Appearance") {
    AppearanceScreen(model: SettingsModel(
        account: InMemoryAccountService(),
        preferences: AtePreferences(store: InMemoryKeyValueStore())
    ))
}

#Preview("How Ate uses AI") {
    AIScreen()
}
#endif

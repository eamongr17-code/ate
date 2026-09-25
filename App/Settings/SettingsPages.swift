import AteKit
import SwiftUI

/// **The three pages Settings opens.** None of them is drawn in `design/v1` — the artboard stops at
/// the row — so each is built from the vocabulary Settings itself uses: the same header (back arrow,
/// `.h` 24), the same 56pt rows ruled at the top, the same gutter. A page pushed from a list of rows
/// is a list of rows.

/// A pushed settings page: the header, then its content from `padding:14px 20px 0`.
struct AteSettingsPage<Content: View>: View {
    let title: String
    let onBack: () -> Void
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
        .safeAreaInset(edge: .top, spacing: 0) {
            AtePageHeader(title: title, onBack: onBack)
                .background(AtePalette.automatic.ground)
        }
        .ateGround()
    }

    /// `padding:14px 20px 0` under the header.
    static var contentTop: CGFloat { 14 }
}

/// **Appearance** — System, Light, Dark. The chosen one carries the check the handle field uses;
/// the others carry nothing.
struct AppearanceScreen: View {
    let model: SettingsModel
    var onBack: () -> Void = {}

    var body: some View {
        AteSettingsPage(title: "Appearance", onBack: onBack) {
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
    var onBack: () -> Void = {}

    var body: some View {
        AteSettingsPage(title: "How Ate uses AI", onBack: onBack) {
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

/// The words on that page.
///
/// **COPY PROPOSAL — not approved.** Drafted by engineering from `docs/PRODUCT.md` (your words are
/// saved as written and never rewritten; the sorter only adds structure; scores are never inferred;
/// places are never assumed) and from what `supabase/functions/sort-entry` actually does. This is
/// public-facing product copy, so it is Eamon's to approve or rewrite (AGENTS.md escalation c) before
/// it leaves internal TestFlight. Two claims in it need checking against the provider's terms and
/// the sorter's live mode before they ship: that the words are not used for training, and that
/// photos and voice never reach the model.
enum AICopy {
    static let isProposal = true

    static let paragraphs: [String] = [
        "When you finish an entry, your words are sent to Ate's server, where an AI model reads them "
            + "and works out the place, the dishes and the score you gave each one. That's the receipt.",
        "It only adds structure. Your words are saved exactly as you wrote them, before the model "
            + "sees them, and are never rewritten.",
        "It never guesses a score you didn't give, and never picks a place you didn't name. "
            + "Anything it gets wrong, tap it and fix it.",
        "Only the words go. Your photos stay with your entry, and dictation is your keyboard's own, "
            + "so Ate never hears your voice.",
        "Your entries aren't used to train AI models."
    ]
}

/// **Blocked people** — who, and one way to undo it.
///
/// Nobody blocked draws nothing under the header: an empty list is the state, and a line saying so
/// would be helper copy (design rule 1).
struct BlockedPeopleScreen: View {
    @State var store: BlockedPeopleStore
    var onBack: () -> Void = {}

    var body: some View {
        AteSettingsPage(title: "Blocked people", onBack: onBack) {
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

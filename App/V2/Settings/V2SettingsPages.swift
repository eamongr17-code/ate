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

/// **Diet** (`design/rebuild/diet.html`) — the same tick list as Appearance, except several can be
/// ticked, in two groups, "Diets" and "Allergies" (`diet-more.html`). Each tap saves at once. A code
/// ticks what it covers as well (Vegan: Vegetarian, Pescatarian, Dairy free, Egg free), faded and
/// locked. A refused write puts the tick back and says so once.
struct V2DietPage: View {
    let diet: DietStore

    @State private var failure: ActionFailure?

    var body: some View {
        let choice = diet.choice ?? DietChoice()
        List {
            // Ten rows read as two lists (`diet-more.html`): the headers say plainly which is which.
            Section("Diets") { rows(DietTag.diets, choice: choice) }
            Section("Allergies") { rows(DietTag.allergies, choice: choice) }
        }
        .ateGroupedList()
        .ateInlineTitle("Diet")
        .ateFailureAlert($failure)
        .task { await diet.loadIfNeeded() }
    }

    private func rows(_ tags: [DietTag], choice: DietChoice) -> some View {
        ForEach(tags, id: \.self) { tag in
            let isCovered = choice.isCovered(tag)
            let isTicked = choice.isPicked(tag) || isCovered
            AteGroupedRow(
                title: tag.dietName, showsChevron: false, isCovered: isCovered,
                identifier: "settings.diet.\(tag.rawValue)"
            ) {
                AteHaptics.key()
                Task { if await diet.toggle(tag) == false { failure = .diet } }
            } trailing: {
                if isTicked {
                    AteIcon.check.view(size: AteMetrics.settingsCheck)
                        .opacity(isCovered ? AteKitColor.disabledOpacity : 1)
                        .accessibilityLabel("Selected")
                }
            }
            .accessibilityAddTraits(isTicked ? .isSelected : [])
        }
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

/// **Privacy** and **Terms** — the documents themselves, on the ground, rather than a web page
/// (``LegalDocument``): its headings in the heading voice, its paragraphs and points in the prose.
struct V2LegalPage: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.regular) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.regular)
            .padding(.bottom, AteMetrics.section)
        }
        .ateGround()
        .ateInlineTitle(document.title)
    }

    @ViewBuilder
    private func row(_ block: LegalDocument.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .ateText(.slipDish)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, AteMetrics.regular)
        case .paragraph(let text):
            prose(text)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(verbatim: "•").ateText(.prose).accessibilityHidden(true)
                prose(text)
            }
        }
    }

    /// `**Bold**` and `_italic_` drawn, not printed.
    private func prose(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            .ateText(.prose)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

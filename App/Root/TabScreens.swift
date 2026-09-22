import SwiftUI

/// **`Feed`** — everyone's receipts, the one place you go to decide where to eat next.
///
/// Milestone 1 builds the loop that fills it (write → receipt → journal), so what exists here is the
/// screen's own chrome and the state it is actually in: nothing has been published yet. The slips
/// themselves are `FeedSlip`, already in the kit and already drawn in the gallery.
struct FeedScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                HStack {
                    Text("Feed").ateText(.screenTitle)
                    Spacer(minLength: AteMetrics.snug)
                    AteChip(icon: .place, title: "Melbourne")
                }
                .padding(.horizontal, AteMetrics.gutter)
                .ateContentTop(62)
                AteEmptySlip(label: "Feed", title: "No receipts\nyet.")
            }
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
    }
}

/// **`Search`** — places, dishes, people. Its zero state is the field: a search screen with nothing
/// typed has nothing to say, and saying it anyway would be helper copy (design rule 1).
struct SearchScreen: View {
    @State private var query = ""
    @State private var kind: Kind = .places

    enum Kind: String, CaseIterable, Identifiable {
        case places, dishes, people, saved
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                Text("Search").ateText(.screenTitle)
                AteSearchField(prompt: "Places, dishes, people", text: $query)
                kinds
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentTop(62)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
    }

    private var kinds: some View {
        HStack(spacing: AteMetrics.snug - 2) {
            ForEach(Kind.allCases) { option in
                let isCurrent = option == kind
                Button {
                    kind = option
                } label: {
                    Text(option.title)
                        .ateText(.controlSmall)
                        .padding(.horizontal, AteMetrics.loose)
                        .frame(height: AteMetrics.keyHeight)
                        .background(
                            isCurrent ? AtePalette.automatic.fg : AtePalette.automatic.chip,
                            in: .capsule
                        )
                        .foregroundStyle(isCurrent ? AtePalette.automatic.inverted : AtePalette.automatic.fg)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// **`You`** — the record, as a statement. The three totals are the honest answer for a journal with
/// nothing in it yet, which is why this screen needs no empty state of its own: zeros *are* the state.
struct YouScreen: View {
    var handle: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statement
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentTop(70)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: AteMetrics.loose) {
            AteAvatar(
                userID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                handle: handle ?? "",
                side: 76
            )
            Text(verbatim: handle.map { "@\($0)" } ?? "")
                .ateText(.profileTitle)
        }
    }

    private var statement: some View {
        HStack(spacing: 0) {
            cell("0", "Orders")
            AteDashedLine(axis: .vertical).frame(height: 44)
            cell("0", "Places")
            AteDashedLine(axis: .vertical).frame(height: 44)
            cell("0", "Dishes")
        }
        .padding(.vertical, 14)
        .padding(.bottom, AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(spacing: AteMetrics.tight) {
            Text(value).ateText(.statValue)
            Text(label)
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.paper.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Feed") { FeedScreen().ateGround() }
#Preview("Search") { SearchScreen().ateGround() }
#Preview("You") { YouScreen(handle: "eamon").ateGround() }
#endif

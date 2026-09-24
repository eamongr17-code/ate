import SwiftUI

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
                // `Search.dc.html`: 52 tall, 18 in, on the chip rather than the field.
                AteSearchField(
                    prompt: "Places, dishes, people",
                    text: $query,
                    height: 52,
                    horizontalPadding: 18,
                    background: AtePalette.automatic.chip
                )
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

#if DEBUG
#Preview("Search") { SearchScreen().ateGround() }
#endif

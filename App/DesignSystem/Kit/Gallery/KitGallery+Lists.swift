#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Lists** (`lists-playlists.html`, `lists-notifications.html` §3): the cover, the pick rows and the
/// list receipt.
extension KitGalleryScreen {
    @ViewBuilder
    var lists: some View {
        section("List cover") {
            VStack(spacing: AteMetrics.section) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: AteListCoverMetrics.columnGap), count: 2),
                    alignment: .leading, spacing: AteListCoverMetrics.rowGap
                ) {
                    AteNewListTile(title: "New list") {}
                    AteListTile(id: KitListFixtures.burgers, name: "Melbourne\u{2019}s best burgers", count: 6,
                                covers: KitListFixtures.covers) {}
                    AteListTile(id: KitListFixtures.indian, name: "The best Indian and Mexican dishes", count: 12,
                                covers: Array(KitListFixtures.covers.prefix(1))) {}
                    AteListTile(id: KitListFixtures.pasta, name: "Pasta to bring Mum to", count: 0) {}
                    AteListTileSkeleton()
                }
                AteListCover(id: KitListFixtures.burgers, name: "Melbourne\u{2019}s best burgers",
                             covers: KitListFixtures.covers, style: .hero)
            }
            .padding(.horizontal, AteListCoverMetrics.gutter)
        }
        section("Pick row") {
            VStack(spacing: 0) {
                AtePickRow(photo: .dish(KitListFixtures.burgers, name: "Smash burger", cover: nil),
                           name: "Smash burger", place: "Royal Stacks", score: .personal(Rating(rounding: 4.5)),
                           isSelected: true, isFirst: true) {}
                AtePickRow(photo: .dish(KitListFixtures.indian, name: "Burger of the week", cover: nil),
                           name: "Burger of the week", place: "Easey\u{2019}s", isSelected: false) {}
                AteListTickRow(name: "Pasta to bring Mum to", isOn: true) {}
                AteListTickRow(name: "Date night", isOn: false) {}
            }
            .padding(.horizontal, AteMetrics.gutter)
            .environment(\.atePalette, .surface)
            .background(AtePalette.surface.ground)
        }
        section("List receipt") {
            AteListReceiptStage(content: .preview)
                .padding(.vertical, AteMetrics.section)
                .frame(maxWidth: .infinity)
                .ateAccentGround(AteColor.coral)
        }
    }
}

private enum KitListFixtures {
    static let burgers = UUID(uuidString: "B0E00000-0000-4000-8000-000000000001") ?? UUID()
    static let indian = UUID(uuidString: "B0E00000-0000-4000-8000-000000000002") ?? UUID()
    static let pasta = UUID(uuidString: "B0E00000-0000-4000-8000-000000000003") ?? UUID()
    static let covers = ["asset://burger", "asset://pizza", "asset://cake", "asset://burger"]
}
#endif

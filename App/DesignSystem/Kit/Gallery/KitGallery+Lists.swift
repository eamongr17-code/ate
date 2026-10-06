#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Lists** (`lists-notifications.html` §3): the list card, the pick rows and the list receipt.
extension KitGalleryScreen {
    @ViewBuilder
    var lists: some View {
        section("List card") {
            VStack(spacing: AteListCardMetrics.spacing) {
                AteAddRow(title: "New list") {}
                AteListCard(id: KitListFixtures.burgers, name: "Melbourne\u{2019}s best burgers", count: 6,
                            covers: KitListFixtures.covers) {}
                AteListCard(id: KitListFixtures.indian, name: "The best Indian and Mexican dishes in the inner north",
                            count: 12) {}
                AteListCardSkeleton()
            }
            .padding(.horizontal, AteMetrics.listGutter)
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
    static let covers = ["asset://burger", "asset://pizza", "asset://cake"]
}
#endif

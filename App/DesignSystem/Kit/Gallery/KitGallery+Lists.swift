#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Lists** (`lists-playlists.html`, `lists-notifications.html` §3): the cover and the pick rows.
extension KitGalleryScreen {
    @ViewBuilder
    var lists: some View {
        section("List cover") {
            VStack(spacing: AteMetrics.section) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: AteListCoverMetrics.columnGap), count: 2),
                    alignment: .leading, spacing: AteListCoverMetrics.rowGap
                ) {
                    AteListTile(id: KitListFixtures.burgers, name: "Melbourne\u{2019}s best burgers", count: 6,
                                covers: KitListFixtures.covers) {}
                    AteListTile(id: KitListFixtures.indian, name: "The best Indian and Mexican dishes", count: 12,
                                covers: Array(KitListFixtures.covers.prefix(1))) {}
                    AteListTile(id: KitListFixtures.pasta, name: "Pasta to bring Mum to", count: 0) {}
                    AteListTileSkeleton()
                    AteNewListTile(title: "New list") {}
                }
                AteListCover(id: KitListFixtures.burgers, name: "Melbourne\u{2019}s best burgers",
                             covers: KitListFixtures.covers, style: .hero)
                AteListTile(id: KitListFixtures.pasta, name: "Date night", count: 6,
                            cover: "asset://cake", owner: KitListFixtures.eamon) {}
                    .frame(width: AteListCoverMetrics.hero)
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
        section("Cover and people") {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                VStack(spacing: 0) {
                    AteCoverChoiceRow(title: "Automatic", subtitle: "First 4 dish photos", isOn: false,
                                      isFirst: true) {
                        AteListCover(id: KitListFixtures.burgers, name: "Burgers", covers: KitListFixtures.covers,
                                     style: .row)
                    } action: {}
                    AteSheetSectionLabel(title: "Dish photos")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AteCoverChoiceRow(title: "Smash burger", subtitle: "Royal Stacks", titleStyle: .kitRankedDish,
                                      isOn: true, isFirst: true) {
                        AteThumb(photo: .remote("asset://burger"))
                    } action: {}
                    AteCoverChoiceRow(title: "Margherita", subtitle: "Tipo 00", titleStyle: .kitRankedDish,
                                      isOn: false) {
                        AteThumb(photo: .remote("asset://pizza"))
                    } action: {}
                    AteAddRow(title: "Upload from Photos", icon: .library) {}
                }
                .environment(\.atePalette, .surface)
                .background(AtePalette.surface.ground)
                AteAvatarStack(people: [KitListFixtures.eamon, KitListFixtures.paris])
                AteListInviteRow(
                    owner: KitListFixtures.eamon, line: "@eamon invited you to Date night", meta: "6 dishes",
                    decline: "Decline", accept: "Accept", isFirst: true,
                    onOpen: {}, onDecline: {}, onAccept: {}
                )
                .padding(.horizontal, -AteMetrics.gutter)
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
    }
}

private enum KitListFixtures {
    static let burgers = UUID(uuidString: "B0E00000-0000-4000-8000-000000000001") ?? UUID()
    static let indian = UUID(uuidString: "B0E00000-0000-4000-8000-000000000002") ?? UUID()
    static let pasta = UUID(uuidString: "B0E00000-0000-4000-8000-000000000003") ?? UUID()
    static let eamon = ListPerson(id: burgers, username: "eamon")
    static let paris = ListPerson(id: indian, username: "paris")
    static let covers = ["asset://burger", "asset://pizza", "asset://cake", "asset://burger"]
}
#endif

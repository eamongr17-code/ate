#if DEBUG || BETA
import AteKit
import SwiftUI

extension KitGalleryScreen {

    // MARK: - Composites

    @ViewBuilder
    var composites: some View {
        section("Dish row") {
            VStack(spacing: 0) {
                AteDishRow(photo: KitFixtures.ragu, name: "Tagliatelle al ragù", subtitle: "Tipo 00",
                           score: .average(4.6), isFirst: true, isSaved: saved.contains("row.1"),
                           onSave: { toggle("row.1") }, onOpen: {})
                AteDishRow(photo: KitFixtures.prawn, name: "Lasagne al ragù", tags: [.gf], subtitle: "Grill'd Pasta Co",
                           score: KitFixtures.five, isSaved: saved.contains("row.2"), onSave: { toggle("row.2") })
                AteDishRow(photo: KitFixtures.gnocchi, name: "Gnocchi al ragù bianco", subtitle: "Marameo",
                           isSaved: saved.contains("row.3"), onSave: { toggle("row.3") })
                AteDishRow(photo: KitFixtures.souvlaki, name: KitFixtures.longName, subtitle: KitFixtures.longPlace,
                           score: KitFixtures.six, isSaved: saved.contains("row.4"), onSave: { toggle("row.4") })
            }
            .padding(.horizontal, AteMetrics.gutter)
            caption("Menu, on paper")
            VStack(spacing: 0) {
                AteDishRow(photo: KitFixtures.ragu, name: "Tagliatelle al ragù", subtitle: "24", subtitleIcon: .you,
                           score: .average(4.6), style: .menu(rank: 1), isFirst: true)
                AteDishRow(photo: KitFixtures.prawn, name: "Prawn spaghetti", tags: [.gf], subtitle: "17",
                           subtitleIcon: .you, score: .average(4.4), style: .menu(rank: 2))
                AteDishRow(photo: KitFixtures.focaccia, name: "Focaccia", subtitle: "3", subtitleIcon: .you,
                           style: .menu(rank: 3))
            }
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.bottom, AteMetrics.tornEdgeHeight + AteMetrics.tight)
            .ateSlip()
            .ateTornPaper()
            .ateCardWidth()
        }
        section("Entry slip") {
            VStack(spacing: AteMetrics.slipGap) {
                caption("Journal: no byline, full words, the day")
                AteEntrySlip(slip: .previewJournal, surface: .journal)
                caption("Feed, two dishes: words in two lines")
                AteEntrySlip(slip: .previewFeed, surface: .feed, onSave: { _ in })
                caption("Feed, three dishes: no words")
                AteEntrySlip(slip: KitFixtures.feedThree, surface: .feed, onSave: { _ in })
                caption("Profile, long names, unscored, no photos")
                AteEntrySlip(slip: KitFixtures.long, surface: .profile, onSave: { _ in })
                caption("Place visit: You, no foot line")
                AteEntrySlip(slip: KitFixtures.placeVisit, surface: .placeVisit, onSave: { _ in })
            }
            .ateCardWidth()
        }
        section("Torn edge") {
            VStack(spacing: 0) {
                Color.clear.frame(height: KitGalleryMetrics.paperPadding * 3)
                    .background(AtePaperTone.slip.fill)
                AteTornEdge()
            }
            .ateCardWidth()
        }
        section("Shelf card") {
            AteShelf(items: shelf) { item in
                AteShelfCard(photo: item.photo, name: item.name, place: item.place, score: item.score,
                             isSaved: saved.contains(item.id), onOpen: {}, onSave: { toggle(item.id) })
            }
        }
        section("Hero card") {
            VStack(spacing: AteMetrics.regular) {
                AteHeroCard(photo: KitFixtures.ragu, name: "Tagliatelle al ragù", place: "Tipo 00",
                            score: .average(4.8), isSaved: saved.contains("hero"), onSave: { toggle("hero") })
                AteHeroCard(photo: KitFixtures.pho, name: KitFixtures.longName, place: KitFixtures.longPlace,
                            onSave: { toggle("hero.2") })
            }
            .padding(.horizontal, KitGalleryMetrics.cardMargin)
        }
        section("Ranked row") {
            VStack(spacing: 0) {
                AteRankedRow(rank: 2, photo: KitFixtures.prawn, name: "Prawn dumplings", place: "Shandong Mama",
                             score: .average(4.7), isSaved: saved.contains("ranked.2"), onSave: { toggle("ranked.2") })
                AteRankedRow(rank: 3, photo: KitFixtures.pho, name: "Pho tai", place: "Co Thao",
                             score: .average(4.6), isSaved: saved.contains("ranked.3"), onSave: { toggle("ranked.3") })
                AteRankedRow(rank: 4, photo: KitFixtures.cake, name: KitFixtures.longName, place: KitFixtures.longPlace,
                             score: .average(5), onSave: { toggle("ranked.4") })
                AteRankedRow(rank: 5, photo: KitFixtures.croissant, name: "Pistachio croissant", place: "Lune",
                             isLast: true, onSave: { toggle("ranked.5") })
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
        section("Receipt") {
            VStack(spacing: AteMetrics.section) {
                caption("Printed: dishes lead, place as fine print, no barcode")
                AteReceiptView(receipt: .preview)
                caption("Printing")
                AteReceiptView(receipt: .preview, isPrinting: true)
                caption("One dish")
                AteReceiptView(receipt: .previewSingle)
            }
            .ateCardWidth()
        }
        section("Empty state") {
            AteEmptyState(line: "Nothing\non the tab.", pill: ("Write your first", {}))
                .frame(height: KitGalleryMetrics.emptyHeight)
            AteEmptyState(line: "Nothing saved\nyet.")
                .frame(height: KitGalleryMetrics.emptyHeight)
        }
        section("Skeleton") {
            VStack(spacing: 0) {
                AteSkeleton(kind: .dishRow)
                AteSkeleton(kind: .rankedRow)
            }
            .padding(.horizontal, AteMetrics.gutter)
            ScrollView(.horizontal) {
                HStack(spacing: AteShelfCardMetrics.spacing) {
                    ForEach(0..<3, id: \.self) { _ in AteSkeleton(kind: .shelfCard) }
                }
            }
            .contentMargins(.horizontal, AteMetrics.gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
            AteSkeleton(kind: .hero).padding(.horizontal, KitGalleryMetrics.cardMargin)
            AteSkeleton(kind: .entrySlip).ateCardWidth()
        }
    }

    struct ShelfItem: Identifiable {
        let id: String
        let photo: AtePhoto
        let name: String
        let place: String
        let score: AteScore?
    }

    var shelf: [ShelfItem] {
        [
            ShelfItem(id: "card.1", photo: KitFixtures.ragu, name: "Pappardelle with duck ragù", place: "Tipo 00",
                      score: .average(4.7)),
            ShelfItem(id: "card.2", photo: KitFixtures.souvlaki, name: "Rigatoni alla vodka", place: "Grill Americano",
                      score: .average(4.6)),
            ShelfItem(id: "card.3", photo: KitFixtures.sushi, name: KitFixtures.longName, place: KitFixtures.longPlace,
                      score: KitFixtures.six),
            ShelfItem(id: "card.4", photo: KitFixtures.gnocchi, name: "Agnolotti", place: "Osteria Ilaria", score: nil)
        ]
    }

    // MARK: - Chrome

    @ViewBuilder
    var chrome: some View {
        section("Filter chips") {
            AteFilterChipRow(chips: chips, onClear: { chip in chips.removeAll { $0 == chip } })
            caption(chips.isEmpty ? "No filter on: no row" : "Tap ✕ to take one off")
        }
        section("Root header") {
            VStack(spacing: AteMetrics.section) {
                AteRootHeader(title: .wordmark) {
                    AteGlassItem(icon: .photoStack, label: "Photos", badge: 5) {}
                    AteGlassItem(icon: .calendar, label: "Calendar") {}
                    AteGlassItem(icon: .filter, label: "Filter") {}
                }
                AteRootHeader(title: .text("Feed"), subtitle: "Melbourne") {
                    AteGlassMenuItem(icon: .navigation, label: "Area") { Button("Near me") {} }
                    AteGlassItem(icon: .feed, label: "Cravings") {}
                }
                AteRootHeader(title: .text("You")) {
                    AteGlassItem(icon: .settings, label: "Settings") {}
                }
            }
            caption("In the native bar")
            NavigationStack {
                Color.clear
                    .ateRootToolbar(title: .text("Search")) {
                        Button {} label: { AteIcon.filter.view(size: AteGlassDiscMetrics.glyph) }
                    }
                    .ateGround()
            }
            .frame(height: KitGalleryMetrics.headerHeight)
        }
        section("Sheet scaffold") {
            caption("A choice: close, title, controls, ink pill with its count")
            inlineSheet(height: KitGalleryMetrics.sheetHeight) { filterSheet(inline: true) }
            caption("Pick a row: close, title, search, rows — no pill")
            inlineSheet(height: KitGalleryMetrics.shortSheetHeight) {
                AteSheetScaffold(title: "Where was this?", searchPrompt: "Search places", searchText: $query) {
                    VStack(spacing: 0) {
                        ForEach(["Tipo 00", "Kisume", "Butchers Diner"], id: \.self) { name in
                            AteRadioRow(title: name, subtitle: "CBD", isSelected: name == "Tipo 00") {}
                        }
                    }
                }
            }
            caption("A primary: the ink tick top right")
            inlineSheet(height: KitGalleryMetrics.shortSheetHeight / 2) {
                AteSheetScaffold(title: "Write", primary: .init(icon: .check, label: "Done", isEnabled: false) {}) {
                    EmptyView()
                }
            }
            AteInkPill(title: "Present the filter sheet", size: .empty) { isShowingSheet = true }
                .frame(maxWidth: .infinity)
        }
        section("Actions sheet") {
            inlineSheet(height: KitGalleryMetrics.shortSheetHeight) { actionsSheet }
            AteInkPill(title: "Present the actions sheet", size: .empty) { isShowingActions = true }
                .frame(maxWidth: .infinity)
        }
    }

    func filterSheet(inline: Bool) -> some View {
        AteSheetScaffold(
            title: "Filter",
            commit: .init(title: "Show 12 entries") { isShowingSheet = false },
            onClose: inline ? {} : nil
        ) {
            VStack(spacing: 0) {
                AteSettingsRow(title: "Rating", value: "4.0 and up") {}
                AteSettingsRow(title: "Date", value: "Any time") {}
                HStack(spacing: AteMetrics.tight + 2) {
                    ForEach(DietTag.allCases, id: \.self) { AteDietChip(tag: $0) }
                }
                .padding(.vertical, AteMetrics.regular)
            }
        }
    }

    var actionsSheet: some View {
        AteActionsSheet(
            title: "@jessw",
            blockTitle: "Block @jessw",
            onSave: { toggle("actions") },
            isSaved: saved.contains("actions"),
            onShare: { [AteLegal.site] },
            onReport: {},
            onBlock: {}
        )
    }

    // MARK: - Layout

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: KitGalleryMetrics.itemGap) {
            Text(title)
                .ateText(.pageTitle)
                .padding(.horizontal, AteMetrics.gutter)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            if label.isEmpty == false { caption(label).padding(.horizontal, -AteMetrics.gutter) }
            HStack(spacing: AteMetrics.regular) { content() }
        }
        .padding(.horizontal, AteMetrics.gutter)
    }

    func caption(_ text: String) -> some View {
        Text(text)
            .ateText(.meta)
            .foregroundStyle(AtePalette.automatic.muted)
            .padding(.horizontal, AteMetrics.gutter)
    }

    func inlineSheet(height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(height: height, alignment: .top)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: AteMetrics.sheetTop, topTrailingRadius: AteMetrics.sheetTop, style: .continuous
            ))
            .padding(.horizontal, AteMetrics.cardGutter)
    }

    func toggle(_ id: String) {
        if saved.contains(id) { saved.remove(id) } else { saved.insert(id) }
    }
}
#endif

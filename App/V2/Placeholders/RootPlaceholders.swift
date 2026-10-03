import AteKit
import SwiftUI

// **The four tab roots, as placeholders** (phase 2b): each root's real header — title, inline
// title, glass group — over a list of kit skeletons, so the chrome, the scrolling, the bar's
// minimise and the header's collapse can be judged before any flow lands. Built only from the kit.
// The first row pushes the root's placeholder page.

struct JournalRootPlaceholder: View {
    let router: TabRouter<NoStores>
    @State private var isCollapsed = false
    @State private var isFiltering = false

    var body: some View {
        PlaceholderRootList(router: router, kind: .entrySlip, isCollapsed: $isCollapsed) {
            router.open(.entry(EntryRoute(entryID: PlaceholderIDs.entry)), from: .journal)
        }
        .ateRootToolbar(
            title: .wordmark,
            inline: AteInlineTitle(title: PlaceholderCopy.month),
            isCollapsed: isCollapsed
        ) {
            AteGlassItem(icon: .photoStack, label: "Photos") { router.open(.suggestions, from: .journal) }
            AteGlassItem(icon: .calendar, label: "Calendar") {}
            AteGlassItem(icon: .filter, label: "Filter") { isFiltering = true }
        }
        .sheet(isPresented: $isFiltering) { FilterSheetPlaceholder() }
    }
}

struct FeedRootPlaceholder: View {
    let router: TabRouter<NoStores>
    @State private var isCollapsed = false
    @State private var isPickingCravings = false

    var body: some View {
        PlaceholderRootList(router: router, kind: .rankedRow, isCollapsed: $isCollapsed) {
            router.open(.place(PlaceholderIDs.place), from: .feed)
        }
        .ateRootToolbar(
            title: .text(V2Tab.feed.title),
            subtitle: PlaceholderCopy.city,
            inline: AteInlineTitle(title: V2Tab.feed.title, subtitle: PlaceholderCopy.city),
            isCollapsed: isCollapsed
        ) {
            AteGlassMenuItem(icon: .place, label: "Area") {
                ForEach(PlaceholderCopy.areas, id: \.self) { area in
                    Button(area) {}
                }
            }
            AteGlassItem(icon: .heart, label: "Cravings") { isPickingCravings = true }
        }
        .sheet(isPresented: $isPickingCravings) { FilterSheetPlaceholder(title: "Cravings") }
    }
}

struct SearchRootPlaceholder: View {
    let router: TabRouter<NoStores>
    @State private var isCollapsed = false
    @State private var isFiltering = false

    var body: some View {
        PlaceholderRootList(router: router, kind: .dishRow, isCollapsed: $isCollapsed) {
            router.open(.dish(PlaceholderIDs.dish), from: .search)
        }
        .ateRootToolbar(
            title: .text(V2Tab.search.title),
            inline: AteInlineTitle(title: V2Tab.search.title),
            isCollapsed: isCollapsed
        ) {
            AteGlassItem(icon: .filter, label: "Filter") { isFiltering = true }
        }
        .sheet(isPresented: $isFiltering) { FilterSheetPlaceholder() }
    }
}

struct YouRootPlaceholder: View {
    let router: TabRouter<NoStores>
    @State private var isCollapsed = false

    var body: some View {
        PlaceholderRootList(router: router, kind: .dishRow, isCollapsed: $isCollapsed) {
            router.open(.ratings(score: PlaceholderCopy.ratingsScore))
        }
        .ateRootToolbar(
            title: .text(V2Tab.you.title),
            inline: AteInlineTitle(title: V2Tab.you.title),
            isCollapsed: isCollapsed
        ) {
            AteGlassItem(icon: .settings, label: "Settings") { router.open(.settings(.root)) }
        }
    }
}

/// A root's scrolling list of kit skeletons: the first row opens the root's placeholder page, a
/// re-tap of the tab scrolls back to the top, and the header collapses as it scrolls.
struct PlaceholderRootList: View {
    let router: TabRouter<NoStores>
    let kind: AteSkeleton.Kind
    @Binding var isCollapsed: Bool
    let onOpen: () -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PlaceholderMetrics.spacing(kind)) {
                    Button(action: onOpen) {
                        AteSkeleton(kind: kind, breathes: false)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open")
                    .accessibilityIdentifier("v2.placeholder.open")
                    .id(PlaceholderMetrics.top)
                    ForEach(1..<PlaceholderMetrics.rows, id: \.self) { _ in
                        AteSkeleton(kind: kind)
                    }
                }
                .padding(.horizontal, PlaceholderMetrics.inset(kind))
                .padding(.top, AteMetrics.regular)
            }
            .ateRootCollapse($isCollapsed)
            .onChange(of: router.scrollToTop) { _, _ in
                withAnimation { reader.scrollTo(PlaceholderMetrics.top, anchor: .top) }
            }
        }
        .accessibilityIdentifier("v2.root.\(router.tab.rawValue)")
        .ateGround()
    }
}

/// The placeholders' stand-in values. Each goes when its flow lands and reads the real thing.
enum PlaceholderCopy {
    /// The Feed opens on your Journal's city; the placeholder has no Journal to read.
    static let city = "Melbourne"
    static let areas = ["Near me", "Everywhere", "Melbourne", "Sydney"]
    static let ratingsScore = 5.0
    /// The Journal's inline title is the month of the slips under the bar; here, this month.
    static var month: String {
        Date.now.formatted(.dateTime.month(.wide))
    }
}

enum PlaceholderIDs {
    static let entry = UUID(uuidString: "00000000-0000-4000-8000-0000000002B0")!
    static let place = UUID(uuidString: "00000000-0000-4000-8000-0000000002B1")!
    static let dish = UUID(uuidString: "00000000-0000-4000-8000-0000000002B2")!
}

enum PlaceholderMetrics {
    static let rows = 24
    static let top = "v2.placeholder.top"

    static func spacing(_ kind: AteSkeleton.Kind) -> CGFloat {
        kind == .entrySlip ? AteMetrics.section : 0
    }

    static func inset(_ kind: AteSkeleton.Kind) -> CGFloat {
        AteMetrics.gutter
    }
}

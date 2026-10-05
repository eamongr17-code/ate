import AteKit
import SwiftUI

/// **One of your lists** (`lists-notifications.html` C4–C8) — pushed, the tab bar staying. Its name
/// as the large title, the count under it, then the Feed's ranked row: your order as the numeral,
/// photo or letter tile, dish over place, your score token; no bookmark (these are your own dishes).
/// A tap opens the entry. Long-press drags to reorder (the native move, no edit mode); swipe left
/// removes, with Saved's Undo pill for four seconds. "Add dishes" is the last row. In the bar,
/// Share (the list receipt) and the one native ••• Menu: Rename, Delete list.
struct V2ListPage: View {
    let route: ListRoute
    let context: V2PageContext

    @State private var store: ListStore
    @State private var isCollapsed = false
    @State private var isRenaming = false
    @State private var isPicking = false
    @State private var isConfirmingDelete = false
    @State private var isSharing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ route: ListRoute, context: V2PageContext) {
        self.route = route
        self.context = context
        _store = State(initialValue: ListStore(
            listID: route.id,
            list: route.summary,
            service: context.services.lists,
            shelf: context.app.lists,
            analytics: context.services.analytics
        ))
    }

    var body: some View {
        List {
            AtePageTitle(title: store.name, isLong: true)
                .listPlainRow()
            Text(ListsCopy.dishes(store.list?.itemCount ?? store.count))
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .padding(.top, AteMetrics.snug)
                .padding(.bottom, V2ListPageMetrics.countBottom)
                .padding(.horizontal, AteMetrics.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listPlainRow()
                .accessibilityIdentifier("list.count")
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .atePageCollapse($isCollapsed)
        .ateGround()
        .ateCollapsingTitle(store.name, isCollapsed: isCollapsed)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { undo }
        .animation(reduceMotion ? nil : .default, value: store.undoable?.id)
        .refreshable { await store.refresh() }
        .task { await store.loadIfNeeded() }
        .onChange(of: store.phase) { _, phase in
            if phase == .gone { dismiss() }
        }
        .sheet(isPresented: $isRenaming) {
            ListNameSheet(title: ListsCopy.rename, initial: store.name) { name in
                await store.rename(to: name)
            }
        }
        .sheet(isPresented: $isPicking) {
            ListPickerSheet(list: store, services: context.services)
        }
        .sheet(isPresented: $isSharing) {
            ListShareSheet(
                content: receipt,
                photoURLs: (store.list?.covers ?? []).compactMap(URL.init(string:)),
                analytics: context.services.analytics
            )
        }
        .confirmationDialog(
            ListsCopy.confirmDelete(store.name), isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button(ListsCopy.delete, role: .destructive) {
                Task { if await store.delete() { dismiss() } }
            }
            .accessibilityIdentifier("list.delete.confirm")
        }
        .listsFailureAlert(failure: isPicking || isRenaming ? nil : store.failure) { store.clearFailure() }
        .accessibilityIdentifier("list.page")
    }

    // MARK: - The rows

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ForEach(0..<ListsMetrics.skeletonRows, id: \.self) { _ in
                AteSkeleton(kind: .rankedRow)
                    .padding(.horizontal, AteMetrics.gutter)
                    .listPlainRow()
            }
        case .failed:
            AteEmptyState(line: ListsCopy.unreachable, pill: (ListsCopy.tryAgain, { retry() }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
                .listPlainRow()
        case .empty:
            AteEmptyState(line: ListsCopy.emptyList, pill: (ListsCopy.addDishes, { pick() }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
                .listPlainRow()
                .accessibilityIdentifier("list.empty")
        case .gone:
            EmptyView()
        case .ready:
            rows
            if store.remaining > 0 {
                AteAddRow(title: ListsCopy.addDishes, identifier: "list.add") { pick() }
                    .padding(.horizontal, AteMetrics.gutter)
                    .listPlainRow()
                    .moveDisabled(true)
            }
        }
    }

    private var rows: some View {
        let items = store.items
        let letters = DishLetter.neighbourly(items.map { ($0.dishID, $0.dishName) })
        return ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            AteRankedRow(
                rank: item.position,
                photo: .dish(letters[index], cover: item.photoURL),
                name: item.dishName,
                place: item.restaurantName,
                score: item.score.map(AteScore.personal),
                isLast: index == items.count - 1,
                onOpen: { open(item) }
            )
            .padding(.horizontal, AteMetrics.gutter)
            .listPlainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(ListsCopy.remove, role: .destructive) { remove(item) }
                    .tint(AteColor.destructive)
            }
            .accessibilityAction(named: ListsCopy.remove) { remove(item) }
            .accessibilityIdentifier("list.row")
        }
        .onMove { source, destination in
            AteHaptics.key()
            Task { await store.move(fromOffsets: source, toOffset: destination) }
        }
    }

    // MARK: - The bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.items.isEmpty == false {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSharing = true } label: {
                    AteIcon.share.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("Share list")
                .accessibilityIdentifier("list.share")
            }
        }
        if store.list != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { isRenaming = true } label: {
                        Label {
                            Text(ListsCopy.rename)
                        } icon: {
                            AteIcon.edit.barImage(size: V2ListPageMetrics.menuGlyph)
                        }
                    }
                    .accessibilityIdentifier("list.rename")
                    Button(role: .destructive) { isConfirmingDelete = true } label: {
                        Label {
                            Text(ListsCopy.deleteList)
                        } icon: {
                            AteIcon.trash.barImage(size: V2ListPageMetrics.menuGlyph)
                        }
                    }
                    .accessibilityIdentifier("list.delete")
                } label: {
                    AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("list.more")
            }
        }
    }

    // MARK: - Undo

    /// After a remove: Saved's ink pill above the tab bar for four seconds.
    @ViewBuilder
    private var undo: some View {
        if let item = store.undoable {
            AteInkPill(title: ListsCopy.undo, size: .empty, identifier: "list.undo") {
                Task { await store.undoRemove() }
            }
            .accessibilityLabel("Undo, put back \(item.dishName)")
            .padding(.bottom, AteMetrics.regular)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: item.id) {
                try? await Task.sleep(for: ListsMetrics.undoLifetime)
                guard Task.isCancelled == false else { return }
                store.expireUndo(for: item)
            }
        }
    }

    // MARK: - Doing

    /// The receipt: the top ten lines, the place as fine print, signed with your handle.
    private var receipt: AteListReceiptContent {
        let lines = store.items.prefix(ListsMetrics.receiptLines).map { item in
            AteListReceiptContent.Line(
                id: item.id, rank: item.position, dish: item.dishName, score: item.score, place: item.restaurantName
            )
        }
        return AteListReceiptContent(
            title: store.name, lines: Array(lines), count: store.count, date: Date(),
            handle: context.app.handle ?? ""
        )
    }

    private func open(_ item: ListItem) {
        context.open(.entry(EntryRoute(entryID: item.entryID)), from: .journal)
    }

    private func remove(_ item: ListItem) {
        AteHaptics.key()
        Task { await store.remove(item) }
    }

    private func pick() {
        guard context.gate.permitsWrite(.journal) else { return }
        isPicking = true
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

extension View {
    /// A row of a Lists page's plain list: edge to edge on the ground, no system separator (the rows
    /// draw their own rules).
    func listPlainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum V2ListPageMetrics {
    /// The count line: `padding:8px 0 10px`.
    static let countBottom: CGFloat = 10
    /// A ••• Menu item's Lucide glyph.
    static let menuGlyph: CGFloat = 18
}

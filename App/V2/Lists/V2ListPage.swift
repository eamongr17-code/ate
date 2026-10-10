import AteKit
import SwiftUI

/// **One of your lists** (`lists-playlists.html`, approved 9 Oct; `lists-notifications.html` C5–C8)
/// — pushed, the tab bar staying, opened like an album: the cover big and lifted, the name under it,
/// your handle and the count, then Add dishes and Share side by side. Then the rows, numbered like a
/// playlist's tracks: your order as a small numeral, photo or letter tile, dish over place, your score
/// token; no bookmark (these are your own dishes). The name settles into the bar once the cover has
/// scrolled away. A tap opens the entry. Long-press drags to reorder (the native move, no edit mode); swipe left
/// removes, with Saved's Undo pill for four seconds. "Add dishes" is the last row. In the bar,
/// Share (the list as a link) and the one native ••• Menu: Rename, Delete list.
struct V2ListPage: View {
    let route: ListRoute
    let context: V2PageContext

    @State private var store: ListStore
    @State private var isCollapsed = false
    @State private var isRenaming = false
    @State private var isPicking = false
    /// A list just made raises its picker once, the first time the page shows.
    @State private var hasPickedOnOpen = false
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
            hero
                .listPlainRow()
                .moveDisabled(true)
            content
        }
        .listStyle(.plain)
        .accessibilityIdentifier("list.page")
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > V2ListPageMetrics.collapseAfter
        } action: { _, collapsed in
            isCollapsed = collapsed
        }
        .ateGround()
        .ateCollapsingTitle(store.name, isCollapsed: isCollapsed)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { undo }
        .animation(reduceMotion ? nil : .default, value: store.undoable?.id)
        .refreshable { await store.refresh() }
        .task { await store.loadIfNeeded() }
        .onAppear(perform: pickOnOpen)
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
            ListShareSheet(share: share, analytics: context.services.analytics)
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
    }

    // MARK: - The head

    private var hero: some View {
        VStack(spacing: 0) {
            AteListCover(id: route.id, name: store.name, covers: store.list?.covers ?? [], style: .hero)
            Text(store.name)
                .ateText(.kitListHeroName)
                .foregroundStyle(AtePalette.automatic.fg)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, V2ListPageMetrics.nameTop)
                .accessibilityAddTraits(.isHeader)
            byline
                .padding(.top, V2ListPageMetrics.bylineTop)
            HStack(spacing: V2ListPageMetrics.actionGap) {
                AteInkPill(
                    title: ListsCopy.addDishes, isEnabled: store.remaining > 0, identifier: "list.addPill"
                ) { pick() }
                if store.items.isEmpty == false {
                    AteInkPill(title: ListsCopy.share, isQuiet: true, identifier: "list.sharePill") {
                        isSharing = true
                    }
                }
            }
            .padding(.top, V2ListPageMetrics.actionsTop)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.regular)
        .padding(.bottom, V2ListPageMetrics.heroBottom)
        .frame(maxWidth: .infinity)
    }

    /// Your handle on its avatar, then the count — a playlist's owner line.
    private var byline: some View {
        HStack(spacing: V2ListPageMetrics.bylineGap) {
            if let handle = context.app.handle, let userID = context.services.api.currentUserID {
                AteAvatar(userID: userID, handle: handle)
                Text(handle)
                    .ateText(.kitListByline)
                    .foregroundStyle(AtePalette.automatic.fg)
                    .lineLimit(1)
                Text(verbatim: "·")
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            Text(ListsCopy.dishes(store.list?.itemCount ?? store.count))
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .accessibilityIdentifier("list.count")
        }
        .accessibilityElement(children: .combine)
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
            AteEmptyState(line: ListsCopy.unreachable, art: .torn, pill: (ListsCopy.tryAgain, { retry() }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
                .listPlainRow()
        case .empty:
            // The hero's Add dishes is the way in; nothing else to say.
            Color.clear
                .frame(height: 0)
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
                isTrack: true,
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

    /// What leaves: the list as a link, named and covered as its page is.
    private var share: ListShare {
        ListShare(
            id: route.id, name: store.name, count: store.count, covers: store.list?.covers ?? [],
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

    private func pickOnOpen() {
        guard route.picksOnOpen, hasPickedOnOpen == false else { return }
        hasPickedOnOpen = true
        pick()
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
    /// `.hero .nm{margin-top:18px}`, `.by{margin-top:6px; gap:6px}`, `.acts{margin-top:16px; gap:10px}`.
    static let nameTop: CGFloat = 18
    static let bylineTop: CGFloat = 6
    static let bylineGap: CGFloat = 6
    static let actionsTop: CGFloat = 16
    static let actionGap: CGFloat = 10
    static let heroBottom: CGFloat = 16
    /// The name takes the bar once the cover and the name under it have scrolled away.
    static let collapseAfter: CGFloat = AteListCoverMetrics.hero + 60
    /// A ••• Menu item's Lucide glyph.
    static let menuGlyph: CGFloat = 18
}

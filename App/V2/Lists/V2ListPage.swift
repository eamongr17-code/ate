import AteKit
import SwiftUI
import UIKit

/// **One of your lists** (`lists-playlists.html`, approved 9 Oct; `lists-notifications.html` C5–C8)
/// — pushed, the tab bar staying, opened like an album: the cover big and lifted, the name under it,
/// your handle and the count, then Add dishes and Share side by side. Then the rows, numbered like a
/// playlist's tracks: your order as a small numeral, photo or letter tile, dish over place, your score
/// token; no bookmark (these are your own dishes). The name settles into the bar once the cover has
/// scrolled away. A tap opens the entry. Long-press drags to reorder (the native move, no edit mode); swipe left
/// removes, with Saved's Undo pill for four seconds. "Add dishes" is the last row. In the bar,
/// Share (the list as a link) and the one native ••• Menu: Rename, Change cover, Add people, Delete
/// list (`list-cover-edit.html`). Tapping the cover opens the cover sheet too.
///
/// Somebody else's list (screen 9) reads the same but only the owner changes it: no Add dishes, no
/// reordering or removing, and the ••• holds Leave list. Opened from an invite, it is a preview with
/// Decline and Accept where Add dishes would be.
struct V2ListPage: View {
    let route: ListRoute
    let context: V2PageContext

    @State private var store: ListStore
    @State private var isCollapsed = false
    /// Where the header's name ends: the bar takes it once the page has scrolled past.
    @State private var titleBottom: CGFloat = 0
    @State private var isRenaming = false
    @State private var isPicking = false
    /// A list just made raises its picker once, the first time the page shows.
    @State private var hasPickedOnOpen = false
    @State private var isConfirmingDelete = false
    @State private var isCovering = false
    @State private var isAddingPeople = false
    @State private var isConfirmingLeave = false
    @State private var sharing: ShareSender.Sending?
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
        .ateTitleCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .ateCollapsingTitle(store.name, isCollapsed: isCollapsed)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { undo }
        .animation(reduceMotion ? nil : .default, value: store.undoable?.id)
        .ateRefreshable { await store.refresh() }
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
        .sheet(isPresented: $isCovering) {
            ListCoverSheet(list: store)
        }
        .sheet(isPresented: $isAddingPeople) {
            ListPeopleSheet(list: store, services: context.services)
        }
        .sheet(item: $sharing) { sending in
            ShareSheet(sending: sending) { destination in
                context.services.analytics(
                    ShareEvents.listShared(listID: route.id, destination: destination, count: store.count)
                )
            }
            .presentationDetents([.medium, .large])
        }
        .listsFailureAlert(failure: isSheetUp ? nil : store.failure) { store.clearFailure() }
    }

    // MARK: - The head

    private var hero: some View {
        AtePageHeader(store.name, titleBottom: $titleBottom) {
            cover
        } line: {
            byline
        } below: {
            // Whose it is decides the actions: none until the list has been read.
            if store.list != nil {
                actions
            }
        }
        .padding(.bottom, V2ListPageMetrics.heroBottom)
    }

    /// The cover, big and lifted: the picked one, or the mosaic. The owner's opens the cover sheet.
    @ViewBuilder
    private var cover: some View {
        let art = AteListCover(
            id: route.id, name: store.name, covers: store.list?.covers ?? [], cover: store.list?.coverURL,
            style: .hero
        )
        if store.isOwn && store.list != nil {
            Button { isCovering = true } label: { art }
                .buttonStyle(.plain)
                .accessibilityLabel(ListsCopy.changeCover)
                .accessibilityIdentifier("list.cover")
        } else {
            art
        }
    }

    /// The owner, then everyone who accepted, each on their avatar, then the count — a playlist's
    /// owner line. On your own list with people on it, a tap opens Add people.
    @ViewBuilder
    private var byline: some View {
        let line = HStack(spacing: V2ListPageMetrics.bylineGap) {
            let people = bylinePeople
            if people.isEmpty == false {
                if people.count == 1, let only = people.first {
                    AteAvatar(userID: only.id, handle: only.username, url: only.avatarURL.flatMap(URL.init(string:)))
                } else {
                    AteAvatarStack(people: people)
                }
                Text(ListsCopy.byline(people.map(\.username)))
                    .ateText(.pageHeaderStrong)
                    .foregroundStyle(AtePalette.automatic.fg)
                    .lineLimit(1)
                Text(verbatim: "·")
                    .ateText(.pageHeaderLine)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            Text(ListsCopy.dishes(store.list?.itemCount ?? store.count))
                .ateText(.pageHeaderLine)
                .foregroundStyle(AtePalette.automatic.muted)
                .accessibilityIdentifier("list.count")
        }
        .accessibilityElement(children: .combine)
        if store.isOwn && store.people.isEmpty == false {
            Button { isAddingPeople = true } label: { line }
                .buttonStyle(.plain)
                .accessibilityIdentifier("list.people")
        } else {
            line
        }
    }

    /// Yours: Add dishes and Share. Someone else's: Share. An invite's preview: Decline and Accept.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: V2ListPageMetrics.actionGap) {
            switch store.role {
            case .owner:
                AteInkPill(
                    title: ListsCopy.addDishes, isEnabled: store.remaining > 0, identifier: "list.addPill"
                ) { pick() }
                if store.hasDishes {
                    AteInkPill(title: ListsCopy.share, isQuiet: true, identifier: "list.sharePill") {
                        shareList()
                    }
                }
            case .accepted:
                if store.hasDishes {
                    AteInkPill(title: ListsCopy.share, identifier: "list.sharePill") { shareList() }
                }
            case .invited:
                AteInkPill(title: ListsCopy.decline, isQuiet: true, identifier: "list.decline") {
                    answer(accept: false)
                }
                AteInkPill(title: ListsCopy.accept, identifier: "list.accept") { answer(accept: true) }
            }
        }
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
            AteEmptyState(line: ListsCopy.unreachable, art: .unplugged, pill: (ListsCopy.tryAgain, { retry() }))
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
            if store.isOwn && store.remaining > 0 {
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
        // Only the owner reorders; on someone else's list the rows hold still.
        let reorder: ((IndexSet, Int) -> Void)? = store.isOwn ? { move(fromOffsets: $0, toOffset: $1) } : nil
        return ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            row(item, letter: letters[index], isLast: index == items.count - 1)
        }
        .onMove(perform: reorder)
    }

    private func row(_ item: ListItem, letter: DishLetter, isLast: Bool) -> some View {
        AteRankedRow(
            rank: item.position,
            photo: .dish(letter, cover: item.photoURL),
            name: item.dishName,
            place: item.restaurantName,
            score: item.score.map(AteScore.personal),
            isLast: isLast,
            isTrack: true,
            onOpen: { open(item) }
        )
        .padding(.horizontal, AteMetrics.gutter)
        .listPlainRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if store.isOwn {
                AteSwipeRemove(title: ListsCopy.remove) { remove(item) }
            }
        }
        .accessibilityActions {
            if store.isOwn {
                Button(ListsCopy.remove) { remove(item) }
            }
        }
        .accessibilityIdentifier("list.row")
    }

    private func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        AteHaptics.key()
        Task { await store.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: - The bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.hasDishes {
            ToolbarItem(placement: .topBarTrailing) {
                Button { shareList() } label: {
                    AteIcon.share.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("Share list")
                .accessibilityIdentifier("list.share")
            }
        }
        if store.list != nil && store.role != .invited {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if store.isOwn {
                        ownerMenu
                    } else {
                        Button(role: .destructive) { isConfirmingLeave = true } label: {
                            Label {
                                Text(ListsCopy.leaveList)
                            } icon: {
                                AteIcon.userMinus.barImage(size: V2ListPageMetrics.menuGlyph)
                            }
                        }
                        .accessibilityIdentifier("list.leave")
                    }
                } label: {
                    AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("list.more")
                // On the ••• it came from: iOS 26 points the ask at the view it hangs on, and on the
                // page that was the page's middle (Eamon, 28 Oct).
                .confirmationDialog(
                    ListsCopy.confirmDelete(store.name), isPresented: $isConfirmingDelete, titleVisibility: .visible
                ) {
                    Button(ListsCopy.delete, role: .destructive) {
                        Task { if await store.delete() { dismiss() } }
                    }
                    .accessibilityIdentifier("list.delete.confirm")
                }
                .confirmationDialog(
                    ListsCopy.confirmLeave(store.name), isPresented: $isConfirmingLeave, titleVisibility: .visible
                ) {
                    Button(ListsCopy.leave, role: .destructive) {
                        Task { await store.leave() }
                    }
                    .accessibilityIdentifier("list.leave.confirm")
                }
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
}

// MARK: - Doing

extension V2ListPage {
    /// Whose list it is, then who has accepted; nobody still deciding.
    private var bylinePeople: [ListPerson] {
        let owner: ListPerson? = if store.isOwn {
            context.app.handle.flatMap { handle in
                context.services.api.currentUserID.map { ListPerson(id: $0, username: handle) }
            }
        } else {
            store.list?.owner
        }
        let accepted = store.people.filter { $0.status == .accepted && $0.id != owner?.id }
        return (owner.map { [$0] } ?? []) + accepted
    }

    @ViewBuilder
    private var ownerMenu: some View {
        Button { isRenaming = true } label: {
            Label {
                Text(ListsCopy.rename)
            } icon: {
                AteIcon.edit.barImage(size: V2ListPageMetrics.menuGlyph)
            }
        }
        .accessibilityIdentifier("list.rename")
        Button { isCovering = true } label: {
            Label {
                Text(ListsCopy.changeCover)
            } icon: {
                AteIcon.library.barImage(size: V2ListPageMetrics.menuGlyph)
            }
        }
        .accessibilityIdentifier("list.changeCover")
        Button { addPeople() } label: {
            Label {
                Text(ListsCopy.addPeople)
            } icon: {
                AteIcon.userPlus.barImage(size: V2ListPageMetrics.menuGlyph)
            }
        }
        .accessibilityIdentifier("list.addPeople")
        Button(role: .destructive) { isConfirmingDelete = true } label: {
            Label {
                Text(ListsCopy.deleteList)
            } icon: {
                AteIcon.trash.barImage(size: V2ListPageMetrics.menuGlyph)
            }
        }
        .accessibilityIdentifier("list.delete")
    }

    /// What leaves: the list as a link, named and covered as its page is, under its owner's handle.
    private var share: ListShare {
        let covers = store.list?.coverURL.map { [$0] } ?? store.list?.covers ?? []
        let handle = store.isOwn ? context.app.handle : store.list?.owner?.username
        return ListShare(id: route.id, name: store.name, count: store.shownCount, covers: covers, handle: handle ?? "")
    }

    /// A sheet over the page says its own refusals.
    private var isSheetUp: Bool { isPicking || isRenaming || isCovering || isAddingPeople }

    /// Straight to the system share sheet: the link, with the cover and name in its header.
    private func shareList() {
        guard sharing == nil else { return }
        let share = share
        Task {
            let items = await ListLinkShare.items(for: share)
            sharing = ShareSender.Sending(image: UIImage(), items: items)
        }
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

    private func addPeople() {
        guard context.gate.permitsWrite(.journal) else { return }
        isAddingPeople = true
    }

    /// The invite's preview: Accept makes it one of your lists here and now; Decline closes it.
    private func answer(accept: Bool) {
        guard let list = store.list, let owner = list.owner else { return }
        AteHaptics.key()
        let invite = ListInvite(
            listID: route.id, name: list.name, itemCount: store.count, covers: list.covers,
            coverURL: list.coverURL, owner: owner, invitedAt: list.createdAt
        )
        Task {
            guard await context.app.listInvites.respond(to: invite, accept: accept) else { return }
            await context.app.notifications.refreshCount()
            if accept {
                await store.refresh()
            } else {
                dismiss()
            }
        }
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
    /// The header's byline `gap:6px`, its actions `gap:10px`, and 16 before the rows.
    static let bylineGap: CGFloat = 6
    static let actionGap: CGFloat = 10
    static let heroBottom: CGFloat = 16
    /// A ••• Menu item's Lucide glyph.
    static let menuGlyph: CGFloat = 18
}

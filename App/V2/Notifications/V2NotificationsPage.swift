import AteKit
import SwiftUI

/// **Notifications** ("Ate with", `ate-with.html` section 2) — pushed from the bell on You, the tab
/// bar staying. One row type (``AteNotificationRow``), newest first: a tap opens the tag's scoring
/// sheet, the X clears the row (the tag stays), a swipe declines (asked once). Any finished action
/// removes the row. Opening the page is one of the two moments the system's notification prompt may
/// be asked, once.
struct V2NotificationsPage: View {
    let context: V2PageContext

    @State private var isCollapsed = false
    @State private var declining: AteNotification?

    init(context: V2PageContext) {
        self.context = context
    }

    private var store: NotificationsStore { context.app.notifications }

    var body: some View {
        List {
            AtePageTitle(title: NotificationsCopy.title)
                .plainRow()
            switch store.phase {
            case .loading:
                ForEach(0..<NotificationsMetrics.skeletonRows, id: \.self) { index in
                    AteNotificationRowSkeleton(isFirst: index == 0).plainRow()
                }
            case .failed:
                AteEmptyState(
                    line: NotificationsCopy.unreachable, pill: (title: NotificationsCopy.retry, action: retry)
                )
                    .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                    .plainRow()
                    .accessibilityIdentifier("state.unreachable")
            case .ready:
                if store.rows.isEmpty {
                    AteEmptyState(line: NotificationsCopy.empty)
                        .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                        .plainRow()
                        .accessibilityIdentifier("state.empty")
                } else {
                    rows
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .atePageCollapse($isCollapsed)
        .ateGround()
        .ateCollapsingTitle(NotificationsCopy.title, isCollapsed: isCollapsed)
        .ateAnimation(AteMotion.fillIn, value: store.rows.map(\.id))
        .refreshable { await store.refresh() }
        .task {
            await store.refresh()
            context.services.analytics(NotificationEvents.notificationsOpened(unread: store.unreadCount))
            await AtePush.shared.askOnce(trigger: .notifications, services: context.services)
        }
        .confirmationDialog(
            declining.map { NotificationsCopy.declineTitle(handle: $0.actor.username) } ?? "",
            isPresented: Binding(get: { declining != nil }, set: { if $0 == false { declining = nil } }),
            titleVisibility: .visible,
            presenting: declining
        ) { row in
            Button(NotificationsCopy.decline, role: .destructive) { decline(row) }
        }
        .accessibilityIdentifier("notifications.page")
    }

    private var rows: some View {
        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
            AteNotificationRow(
                userID: row.actor.id,
                handle: row.actor.username,
                line: NotificationsCopy.line(handle: row.actor.username),
                meta: NotificationsCopy.meta(row),
                isFirst: index == 0,
                onOpen: { open(row) },
                onClear: { Task { await store.dismiss(row) } }
            )
            .plainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(NotificationsCopy.decline, role: .destructive) { declining = row }
                    .tint(AteColor.destructive)
            }
            .accessibilityAction(named: NotificationsCopy.decline) { declining = row }
            .onAppear {
                if row.id == store.rows.last?.id { Task { await store.loadMore() } }
            }
        }
    }

    private func open(_ row: AteNotification) {
        guard let companionID = row.companionID, context.gate.permitsWrite(.compose) else { return }
        context.services.analytics(NotificationEvents.ateWithOpened(from: .list))
        context.app.compose(.respond(to: companionID))
    }

    private func decline(_ row: AteNotification) {
        declining = nil
        guard let companionID = row.companionID else { return }
        let services = context.services
        store.finished(companionID: companionID)
        services.analytics(NotificationEvents.notificationDismissed(how: .decline))
        Task {
            do {
                try await services.ateWith.decline(companionID: companionID)
            } catch AteWithError.gone {
                // Already withdrawn: the row was right to go.
            } catch {
                await store.refresh()
            }
        }
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

private extension View {
    /// A row of the page's plain list: edge to edge on the ground, no system separator (the rows draw
    /// their own hairline).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum NotificationsCopy {
    static let title = "Notifications"
    static let empty = "Nothing new"
    static let unreachable = "Couldn't reach Ate."
    static let retry = "Try again"
    static let decline = "Decline"

    static func line(handle: String) -> String { "@\(handle) ate with you" }

    static func declineTitle(handle: String) -> String { "Remove yourself from @\(handle)'s entry?" }

    /// Where and when: "Tipo 00, Sat 19 Sep". A place that has gone is not guessed at.
    static func meta(_ row: AteNotification) -> String? {
        let day = row.visitedAt.map { RelativeAge.day($0) }
        let parts = [row.place?.name, day].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum NotificationsMetrics {
    static let skeletonRows = 4
}

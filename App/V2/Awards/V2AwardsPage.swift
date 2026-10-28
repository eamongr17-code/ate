import AteKit
import SwiftUI

/// **The Awards page** (`plate-awards-screens.html`) — one grid, no groups: what has been earned,
/// newest first, each with its day; then the rest as silhouettes with no names. The secret 6 is not
/// there at all until it is earned. Yours from "Your awards ›", or somebody else's from their page.
struct V2AwardsPage: View {
    let route: AwardsRoute
    let context: V2PageContext

    @State private var store: AwardsStore
    @State private var hasCounted = false

    init(route: AwardsRoute, context: V2PageContext) {
        self.route = route
        self.context = context
        _store = State(initialValue: AwardsStore(userID: route.userID, awards: context.services.awards))
    }

    private var userID: UUID? { route.userID }

    var body: some View {
        ScrollView {
            Group {
                switch store.phase {
                case .loading:
                    AteAwardsGridSkeleton()
                        .transition(.opacity)
                case .unavailable:
                    AteEmptyState(
                        line: "Couldn't\nreach Ate.", art: .unplugged,
                        pill: (title: "Try again", action: { Task { await store.refresh() } })
                    )
                    .containerRelativeFrame(.vertical)
                case .ready:
                    grid
                        .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.regular)
            .padding(.bottom, AteMetrics.section)
        }
        .ateRefreshable { await store.refresh() }
        .accessibilityIdentifier("v2.awards")
        .ateGround()
        .ateInlineTitle("Awards")
        .task {
            await store.loadIfNeeded()
            guard hasCounted == false, store.phase == .ready else { return }
            hasCounted = true
            context.services.analytics(AwardEvents.pageViewed(isMe: userID == nil, earned: store.earned.count))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: AteAwardsMetrics.columns, spacing: AteAwardsMetrics.gridRowGap) {
            ForEach(store.cells) { cell in
                AteAwardCell(cell: cell) { award in
                    context.services.analytics(
                        AwardEvents.opened(award: award.award, source: .awardsPage, isMe: userID == nil)
                    )
                    let opened = AwardRoute(userID: userID, award: award.award, handle: route.handle)
                    context.open(.award(opened), from: .award)
                }
            }
        }
    }
}

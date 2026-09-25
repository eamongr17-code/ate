import AteKit
import SwiftUI

/// **`Recap`** — a month, totalled and printed.
///
/// Back and share, and the statement on the linen ground: no tab bar, no month picker, no chrome the
/// artboard does not draw. Months are turned by **swiping the paper**, which is the only way to walk
/// them without inventing a control Eamon has not seen — and the same gesture the system's own
/// month-at-a-time screens use. Only months that exist are in the deck: a month with nothing in it
/// was never printed (design rule 4).
struct RecapScreen: View {
    let handle: String
    let analytics: AnalyticsRecorder

    /// Owned, not handed in — see ``RatingsScreen``: a destination's body is re-evaluated whenever
    /// the shell around it changes, and a store built in that expression would turn the page back
    /// to the month it was pushed with.
    @State private var store: StatementStore
    @State private var isSharing = false
    @Environment(\.dismiss) private var dismiss

    init(
        month: StatementMonth,
        stats: any StatsReading,
        handle: String,
        analytics: @escaping AnalyticsRecorder
    ) {
        self.handle = handle
        self.analytics = analytics
        _store = State(initialValue: StatementStore(month: month, stats: stats))
    }

    var body: some View {
        ZStack {
            if store.all.isEmpty {
                page(store.month)
            } else {
                TabView(selection: month) {
                    ForEach(store.all) { month in
                        page(month)
                            .tag(month)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .task {
            await store.loadIfNeeded()
            analytics(YouEvents.statementViewed(month: store.month))
            #if DEBUG
            // `-ate-open-recap -ate-dump-share`: a drive photographs the statement's own share card.
            if ProcessInfo.processInfo.arguments.contains("-ate-dump-share"), store.statement != nil {
                isSharing = true
            }
            #endif
        }
        .fullScreenCover(isPresented: $isSharing) { shareScreen }
    }

    /// The page the deck is on. Turning it reports the month and reads one ahead, so the next swipe
    /// lands on a printed receipt rather than on blank paper.
    private var month: Binding<StatementMonth> {
        Binding(
            get: { store.month },
            set: { turned in
                guard turned != store.month else { return }
                Task {
                    await store.show(turned)
                    analytics(YouEvents.statementViewed(month: turned))
                    if let older = store.older { await store.prepare(older) }
                    if let newer = store.newer { await store.prepare(newer) }
                }
            }
        )
    }

    /// `padding:60px 12px 0` — back, and the share that sends this statement out.
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            AteIconButton(icon: .share, label: "Share statement", size: 22) { isSharing = true }
                .disabled(store.statement == nil)
                .opacity(store.statement == nil ? 0.35 : 1)
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    /// `margin:4px 34px 0` — the statement is narrower than the screen's own gutter, because a
    /// receipt is held in the hand.
    @ViewBuilder
    private func page(_ month: StatementMonth) -> some View {
        ScrollView {
            Group {
                if let statement = store.statement(for: month) {
                    StatementReceiptView(statement: statement, handle: handle)
                } else {
                    // A month still printing. The paper's own silhouette, not a spinner.
                    StatementSkeleton()
                }
            }
            .padding(.horizontal, RecapScreen.inset)
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
    }

    private static let inset: CGFloat = 34

    @ViewBuilder
    private var shareScreen: some View {
        if let statement = store.statement {
            ShareScreen(
                artefact: .statement(statement, handle: handle),
                source: .statement,
                analytics: analytics
            )
        }
    }
}

/// A statement that has not landed: the paper, its rules and its torn edge, with the figures blank.
private struct StatementSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(spacing: AteMetrics.tight) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AtePalette.slip.hairline)
                    .frame(width: 78, height: 11)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AtePalette.slip.hairline)
                    .frame(width: 186, height: 38)
            }
            .frame(maxWidth: .infinity)
            AteDashedRule()
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AtePalette.slip.hairline)
                    .frame(height: 13)
                    .padding(.vertical, 4)
            }
            AteDashedRule()
            AteBarcode().opacity(0.25)
        }
        .padding(.top, 22)
        .padding(.horizontal, 18)
        .padding(.bottom, AteMetrics.loose + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ateSlip()
        .background(AteColor.slip, in: ReceiptPaper())
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Recap") {
    RecapScreen(
        month: StatementMonth(year: 2026, month: 9),
        stats: InMemoryStatsService(),
        handle: "eamon",
        analytics: { _ in }
    )
}
#endif

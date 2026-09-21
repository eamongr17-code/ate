import AteKit
import SwiftUI

/// **`Main`** — home. The logo, the Journal | Saved segment, and your entries newest first.
///
/// Journal is the app's front door (PRODUCT.md decision 1): you write for yourself, and the record
/// you keep is the first thing you see. Saved lives beside it because a dish you meant to eat belongs
/// next to the dishes you did.
struct JournalScreen: View {
    let services: AteServices
    /// Bumped when the Journal tab is tapped while already current.
    var scrollToTopSignal = 0
    let onCompose: () -> Void

    enum Shelf: Hashable {
        case journal, saved
    }

    @State private var shelf: Shelf = .journal

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    AteSegments(
                        options: [AteSegment(Shelf.journal, "Journal"), AteSegment(Shelf.saved, "Saved")],
                        selection: $shelf
                    )
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, AteMetrics.loose)
                    .id(Self.topAnchor)
                    shelfContent
                        .padding(.top, AteMetrics.section)
                }
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
    }

    private static let topAnchor = "journal.top"

    private var header: some View {
        HStack {
            AteWordmark()
            Spacer(minLength: AteMetrics.snug)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteMetrics.contentTop)
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch shelf {
        case .journal:
            AteEmptySlip(
                label: "Order #0001",
                title: "Nothing\non the tab.",
                prose: "Eat something good,\nthen tell us about it.",
                actionTitle: "Write your first",
                action: onCompose
            )
        case .saved:
            AteEmptySlip(label: "Saved", title: "Nothing saved\nyet.")
        }
    }
}

#if DEBUG
#Preview("Journal") {
    JournalScreen(
        services: AteServices(environment: AteEnvironment(
            name: .staging,
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "preview"
        )),
        onCompose: {}
    )
    .ateGround()
}
#endif

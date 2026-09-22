import SwiftUI

/// The five places the app goes. `compose` is not a destination — it is the ink circle in the middle,
/// and it presents rather than switches.
enum AteTab: String, CaseIterable, Identifiable, Hashable {
    case journal, feed, search, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: "Journal"
        case .feed: "Feed"
        case .search: "Search"
        case .you: "You"
        }
    }

    var icon: AteIcon {
        switch self {
        case .journal: .journal
        case .feed: .feed
        case .search: .search
        case .you: .you
        }
    }
}

/// **One floating pill, 66 high**: Journal · Feed · **+** · Search · You. Icon over a 10.5pt label;
/// the current tab is foreground and bold, the rest are muted.
///
/// Hand-built rather than a `TabView` bar because the design puts a compose *action* in the middle of
/// it — a slot that presents a sheet instead of selecting a tab — and floats the whole thing over
/// content that fades away beneath it. Those are the two things a stock tab bar cannot be talked into.
struct AteTabBar: View {
    @Binding var selection: AteTab
    let onCompose: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            tab(.journal)
            tab(.feed)
            composeButton
            tab(.search)
            tab(.you)
        }
        .padding(.horizontal, 6)
        .frame(height: AteMetrics.tabBarHeight)
        .ateBackground(palette.chip, in: .capsule, shadow: .tabBar)
        .padding(.horizontal, AteMetrics.tabBarInset)
        // The design floats the bar 22 from the *screen's* bottom edge, not from the home
        // indicator's — the indicator is drawn over it, which is what a floating bar is for.
        .padding(.bottom, AteMetrics.tabBarBottom - AteScreen.safeArea.bottom)
    }

    private func tab(_ tab: AteTab) -> some View {
        let isCurrent = tab == selection
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                tab.icon.view(size: 22)
                Text(tab.title)
                    .ateText(isCurrent ? .tabLabelActive : .tabLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(.rect)
        }
        .foregroundStyle(isCurrent ? palette.fg : palette.muted)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var composeButton: some View {
        Button(action: onCompose) {
            AteIcon.compose.view(size: 26, lineWidth: 2.2)
                .frame(width: AteMetrics.composeButton, height: AteMetrics.composeButton)
                .background(palette.fg, in: .circle)
                .foregroundStyle(palette.inverted)
        }
        .padding(.horizontal, 6)
        .accessibilityLabel("New entry")
    }
}

/// Design rule 10: lists and receipts that continue run off the bottom of the screen, and **content
/// fades to the ground** under the floating bar — no rule, no bar background, no hard stop.
struct AteTabScrim: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: palette.ground, location: 0),
                .init(color: palette.ground, location: 0.42),
                .init(color: palette.ground.opacity(0), location: 1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: AteMetrics.scrimHeight)
        // `.scrim` is pinned to the bottom of the screen, under the bar and under the indicator.
        .padding(.bottom, -AteScreen.safeArea.bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
private struct TabBarPreview: View {
    @State private var selection = AteTab.journal

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: AteMetrics.slipGap) {
                    ForEach(0..<12, id: \.self) { index in
                        Text(verbatim: "Row \(index)")
                            .ateText(.prose)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AteMetrics.gutter)
                    }
                }
            }
            AteTabScrim()
            AteTabBar(selection: $selection, onCompose: {})
        }
        .ateGround()
    }
}

#Preview("Tab bar") { TabBarPreview() }
#endif

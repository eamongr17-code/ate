import AteKit
import SwiftUI

/// The four places the app goes. Compose is not one of them — it is the glass `+` beside the bar,
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
        case .feed: AteRound6Explore.feedIcon ?? .feed
        case .search: .search
        case .you: .you
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A switch of tabs, told to the bar that is arriving so its pill can slide over from the tab just
/// left — once, not again on every pop back to the root.
struct AteTabArrival: Equatable {
    var from: AteTab
    var id: Int
}

/// **The tab bar** (round 5: the app's own, in place of iOS 26's `TabView` bar, which clashed with
/// everything custom around it). It keeps the system bar's look, pixel for pixel at rest: a glass
/// capsule of four tabs — the line icon (24) over a brand label (Bricolage 10.5; bold and on
/// a pill when current) — and a separate glass `+` beside it, with the round-4 light shadow.
///
/// It minimises on the way down to the current tab alone in a small disc (the `+` shrinks beside
/// it), and comes back whole on the way up or on a tap of that disc — one capsule morphing into the
/// disc and back on a soft spring (round 5, Eamon's pick). Each tab root carries its own, so it
/// slides away with the root on a push and back in with it on a pop, the finger driving it.
struct AteTabBar: View {
    let chrome: AteTabChrome
    /// The tab whose root carries this bar. Only the current tab's bar is reachable (VoiceOver,
    /// UI tests); `nil` in the gallery.
    var root: AteTab?
    let onSelect: (AteTab) -> Void
    let onExpand: () -> Void
    let onCompose: () -> Void

    /// Where the pill is sliding in from, for the length of one slide; otherwise it sits on `current`.
    @State private var pill: AteTab?
    @State private var consumedArrival: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Metrics = AteTabBarMetrics

    private var current: AteTab { chrome.current }
    private var arrival: AteTabArrival? { chrome.arrival }
    private var isExpanded: Bool { chrome.isExpanded }
    /// Where everything sits, full and minimised (`TabBarGeometry`, tested in AteKit).
    private var geometry: TabBarGeometry {
        TabBarGeometry(width: AteScreen.width - 2 * Metrics.inset, tabCount: AteTab.allCases.count)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            morph
            plus
        }
        .frame(width: geometry.width, height: Metrics.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : AteMotion.barMorph, value: isExpanded)
        .onAppear(perform: syncPill)
        .onChange(of: arrival) { _, _ in syncPill() }
        .onChange(of: current) { _, _ in syncPill() }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            // What the bar is drawing, for the UI tests (`TabChromeUITests`).
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("tabbar.state")
                .accessibilityValue("\(isExpanded ? "expanded" : "minimised") \(current.rawValue)")
        }
        #endif
        // Only the tab on screen has a bar anyone can reach.
        .ateAccessibilityHidden(root.map { $0 != current } ?? false)
    }

    // MARK: - One capsule that morphs into the disc and back

    private var morph: some View {
        let capsule = geometry.capsule(isExpanded: isExpanded)
        return ZStack(alignment: .topLeading) {
            AteGlassSurface(shape: Capsule(), shadow: .bar)
                .frame(width: capsule.width, height: capsule.height)
                .offset(x: capsule.minX, y: capsule.minY)
            ZStack(alignment: .topLeading) {
                selectionPill
                    .opacity(isExpanded ? 1 : 0)
                ForEach(AteTab.allCases) { tab in
                    let isShown = isExpanded || tab == current
                    itemFace(tab, showsLabel: isExpanded)
                        .scaleEffect(isShown ? 1 : 0.5)
                        // Folded, a face is placed by its *icon*, dead centre in the disc — the face
                        // on the disc's centre left the icon 7 high (round 6).
                        .position(isExpanded ? geometry.expandedFace(tab.index) : geometry.minimisedFace)
                        .opacity(isShown ? 1 : 0)
                }
            }
            // The tabs only ever show inside the glass as it grows and shrinks.
            .mask(alignment: .topLeading) {
                Capsule()
                    .frame(width: capsule.width, height: capsule.height)
                    .offset(x: capsule.minX, y: capsule.minY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true) // decoration; the controls below are what VoiceOver meets
            controls
        }
    }

    // MARK: - Parts

    /// The minimised bar's one control: the current tab, which brings the whole bar back.
    private var disc: some View {
        Button(action: onExpand) {
            Color.clear
                .frame(width: TabBarGeometry.minimised, height: TabBarGeometry.minimised)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(current.title)
        .accessibilityIdentifier("tabbar.minimised")
        .ateLargeContent(icon: current.icon, title: current.title)
    }

    /// What the bar draws is decoration that moves; what it offers — the four tabs when full, the
    /// one disc when minimised — is a separate, still layer of controls that exists only in the state
    /// it belongs to, so VoiceOver and a finger only ever meet what is on screen.
    @ViewBuilder
    private var controls: some View {
        if isExpanded {
            ForEach(AteTab.allCases) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Color.clear
                        .frame(width: geometry.slot, height: Metrics.height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == current ? .isSelected : [])
                .accessibilityIdentifier("tabbar.\(tab.rawValue)")
                .ateLargeContent(icon: tab.icon, title: tab.title)
                .position(geometry.slotCentre(tab.index))
            }
        } else {
            disc.offset(x: geometry.discInset, y: geometry.discInset)
        }
    }

    /// A tab as drawn: the line icon over its label.
    private func itemFace(_ tab: AteTab, showsLabel: Bool) -> some View {
        VStack(spacing: 0) {
            AteTabBarItemIcon(tab: tab, isCurrent: tab == current)
                .padding(.top, TabBarGeometry.iconTop)
            Text(tab.title)
                .ateText(tab == current ? .tabLabelActive : .tabLabel)
                .foregroundStyle(tab == current ? AteGlassColor.itemCurrent : AteGlassColor.item)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, Metrics.labelGap)
                .opacity(showsLabel ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: geometry.slot, height: Metrics.height)
        .accessibilityHidden(true)
    }

    private var selectionPill: some View {
        Capsule()
            .fill(AteGlassColor.selection)
            .frame(width: TabBarGeometry.pillWidth, height: Metrics.height - 2 * TabBarGeometry.pillInset)
            .offset(x: geometry.pillMinX((pill ?? current).index), y: TabBarGeometry.pillInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var plus: some View {
        let frame = geometry.plus(isExpanded: isExpanded)
        return Button(action: onCompose) {
            AteIcon.compose.view(size: Metrics.plusIcon)
                .foregroundStyle(AteGlassColor.item)
                .frame(width: frame.width, height: frame.height)
                .background { AteGlassSurface(shape: Circle(), shadow: .bar) }
                .contentShape(.circle)
        }
        .buttonStyle(AteGlassPressStyle())
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel("New entry")
        .accessibilityIdentifier("tabbar.compose")
        .ateLargeContent(icon: .compose, title: "New entry")
    }

    /// The pill follows the tab. Arriving from another tab, it starts on the one just left and
    /// slides across — once per switch.
    private func syncPill() {
        guard let arrival, arrival.id != consumedArrival else { return }
        consumedArrival = arrival.id
        guard arrival.from != current, reduceMotion == false else { return }
        pill = arrival.from
        Task { @MainActor in
            withAnimation(AteMotion.barMorph) { pill = nil }
        }
    }
}

private extension View {
    /// The large-content viewer the system bar gave its items: with the largest accessibility text
    /// sizes, a long press on a tab (or `+`) shows its icon and name large, since the bar's own type
    /// is capped at 14.
    func ateLargeContent(icon: AteIcon, title: String) -> some View {
        accessibilityShowsLargeContentViewer {
            Label { Text(title) } icon: { icon.view(size: AteMetrics.tabIcon) }
        }
    }
}

/// A tab's icon, in the bar's ink: a touch deeper when current, as the system bar drew it.
struct AteTabBarItemIcon: View {
    let tab: AteTab
    let isCurrent: Bool

    var body: some View {
        tab.icon.view(size: AteMetrics.tabIcon)
            .foregroundStyle(isCurrent ? AteGlassColor.itemCurrent : AteGlassColor.item)
            .frame(width: AteMetrics.tabIcon, height: AteMetrics.tabIcon)
    }
}

/// Where the bar stands on the screen — 21 in from each side and 21 up from the bottom, as iOS 26's
/// bar did (build 80). Everything inside it is ``TabBarGeometry``'s (AteKit, tested).
@MainActor
enum AteTabBarMetrics {
    static let height: CGFloat = TabBarGeometry.height
    static let inset: CGFloat = 21
    static let bottom: CGFloat = 21
    static let labelGap: CGFloat = 2
    static let plusIcon: CGFloat = 24
    /// The strip a tab root keeps clear for the bar: from the bar's top to the screen's bottom.
    static var reserve: CGFloat { height + bottom }
    /// What a tab root's list adds under its last row, past the home indicator's own inset, so it
    /// clears the bar exactly as it cleared the system bar (whose strip was the safe area).
    /// `bottomInset` is the page's own bottom safe area, read from layout — never from the window
    /// while a body is being built (that re-entered layout and froze the shell).
    static func rootClearance(bottomInset: CGFloat) -> CGFloat { max(0, reserve - bottomInset) }
    /// A Face ID phone's home-indicator inset: the first frame's guess, before layout has said.
    static let homeIndicatorInset: CGFloat = 34
}

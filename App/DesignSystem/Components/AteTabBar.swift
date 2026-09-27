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
        case .feed: .feed
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

    var body: some View {
        let width = AteScreen.width - 2 * Metrics.inset
        ZStack(alignment: .topLeading) {
            morph(width: width)
            plus(width: width)
        }
        .frame(width: width, height: Metrics.height, alignment: .topLeading)
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

    private func morph(width: CGFloat) -> some View {
        let capsule = capsuleRect(width: width)
        return ZStack(alignment: .topLeading) {
            AteGlassSurface(shape: Capsule(), shadow: .bar)
                .frame(width: capsule.width, height: capsule.height)
                .offset(x: capsule.minX, y: capsule.minY)
            ZStack(alignment: .topLeading) {
                selectionPill(capsuleWidth: width - Metrics.gap - Metrics.height)
                    .opacity(isExpanded ? 1 : 0)
                ForEach(AteTab.allCases) { tab in
                    let isShown = isExpanded || tab == current
                    itemFace(tab, showsLabel: isExpanded)
                        .scaleEffect(isShown ? 1 : 0.5)
                        .opacity(isShown ? 1 : 0)
                        .position(isExpanded ? slotCentre(tab) : discCentre)
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
                .frame(width: Metrics.minimised, height: Metrics.minimised)
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
                        .frame(width: Metrics.slot, height: Metrics.height)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == current ? .isSelected : [])
                .accessibilityIdentifier("tabbar.\(tab.rawValue)")
                .ateLargeContent(icon: tab.icon, title: tab.title)
                .position(slotCentre(tab))
            }
        } else {
            disc.offset(x: Metrics.discInset, y: Metrics.discInset)
        }
    }

    /// A tab as drawn: the line icon over its label.
    private func itemFace(_ tab: AteTab, showsLabel: Bool) -> some View {
        VStack(spacing: 0) {
            AteTabBarItemIcon(tab: tab, isCurrent: tab == current)
                .padding(.top, Metrics.iconTop)
            Text(tab.title)
                .ateText(tab == current ? .tabLabelActive : .tabLabel)
                .foregroundStyle(tab == current ? AteGlassColor.itemCurrent : AteGlassColor.item)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, Metrics.labelGap)
                .opacity(showsLabel ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: Metrics.slot, height: Metrics.height)
        .accessibilityHidden(true)
    }

    private func selectionPill(capsuleWidth: CGFloat) -> some View {
        let shown = pill ?? current
        let centre = slotCentre(shown).x
        let minX = Metrics.pillInset
        let maxX = capsuleWidth - Metrics.pillInset - Metrics.pillWidth
        let left = min(max(centre - Metrics.pillWidth / 2, minX), maxX)
        return Capsule()
            .fill(AteGlassColor.selection)
            .frame(width: Metrics.pillWidth, height: Metrics.height - 2 * Metrics.pillInset)
            .offset(x: left, y: Metrics.pillInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func plus(width: CGFloat) -> some View {
        let side = isExpanded ? Metrics.height : Metrics.minimised
        let centre = CGPoint(x: width - Metrics.height / 2, y: Metrics.height / 2)
        return Button(action: onCompose) {
            AteIcon.compose.view(size: Metrics.plusIcon)
                .foregroundStyle(AteGlassColor.item)
                .frame(width: side, height: side)
                .background { AteGlassSurface(shape: Circle(), shadow: .bar) }
                .contentShape(.circle)
        }
        .buttonStyle(AteGlassPressStyle())
        .position(centre)
        .accessibilityLabel("New entry")
        .accessibilityIdentifier("tabbar.compose")
        .ateLargeContent(icon: .compose, title: "New entry")
    }

    // MARK: - Geometry

    private func capsuleRect(width: CGFloat) -> CGRect {
        isExpanded
            ? CGRect(x: 0, y: 0, width: width - Metrics.gap - Metrics.height, height: Metrics.height)
            : CGRect(x: Metrics.discInset, y: Metrics.discInset, width: Metrics.minimised, height: Metrics.minimised)
    }

    private func slotCentre(_ tab: AteTab) -> CGPoint {
        CGPoint(x: Metrics.capsulePadding + Metrics.slot * (CGFloat(tab.index) + 0.5), y: Metrics.height / 2)
    }

    private var discCentre: CGPoint {
        CGPoint(x: Metrics.discInset + Metrics.minimised / 2, y: Metrics.height / 2)
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

/// The bar's geometry, read off iOS 26's own bar on a 402pt phone (build 80): a 62 capsule 21 in
/// from each side and 21 up from the bottom, the `+` a 62 disc 8 beside it; four 69pt slots inside
/// 7 of padding; the current tab's pill 76×54, 4 in; minimised, a 48 disc 7 in, the `+` 48 on the
/// same centre.
@MainActor
enum AteTabBarMetrics {
    static let height: CGFloat = 62
    static let inset: CGFloat = 21
    static let bottom: CGFloat = 21
    static let gap: CGFloat = 8
    static let capsulePadding: CGFloat = 23.0 / 3.0
    static var slot: CGFloat {
        (AteScreen.width - 2 * inset - gap - height - 2 * capsulePadding) / CGFloat(AteTab.allCases.count)
    }
    static let pillWidth: CGFloat = 76
    static let pillInset: CGFloat = 4
    static let minimised: CGFloat = 48
    static var discInset: CGFloat { (height - minimised) / 2 }
    static let iconTop: CGFloat = 12
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

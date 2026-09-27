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
/// capsule of four tabs — the ported line icon (24) over a brand label (Bricolage 10.5; bold and on
/// a pill when current) — and a separate glass `+` beside it, with the round-4 light shadow.
///
/// It minimises on the way down to the current tab alone in a small disc (the `+` shrinks beside
/// it), and comes back whole on the way up or on a tap of that disc — animated both ways
/// (`-ate-r5-nav`: A a spring morph, B a drop-and-rise swap). Each tab root carries its own, so it
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
            switch AteChromeVariant.nav {
            case .a: morph(width: width)
            case .b: swap(width: width)
            }
            plus(width: width)
        }
        .frame(width: width, height: Metrics.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : motion, value: isExpanded)
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
        // Only ever `true` here: an outer `accessibilityHidden(false)` overrode the minimised bar's
        // own hiding of its tabs.
        .modifier(AteAccessibilityHiddenIf(isHidden: root.map { $0 != current } ?? false))
    }

    private var motion: Animation {
        switch AteChromeVariant.nav {
        case .a: AteMotion.barMorph
        case .b: AteMotion.barSwap
        }
    }

    // MARK: - Variant A: one capsule that morphs into the disc and back

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
                    item(tab, showsLabel: isExpanded)
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
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(isExpanded == false)
            disc
                .offset(x: Metrics.discInset, y: Metrics.discInset)
                .allowsHitTesting(isExpanded == false)
                .accessibilityHidden(isExpanded)
        }
    }

    // MARK: - Variant B: the full bar drops away as the disc rises in its place (and back)

    private func swap(width: CGFloat) -> some View {
        let capsuleWidth = width - Metrics.gap - Metrics.height
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                AteGlassSurface(shape: Capsule(), shadow: .bar)
                    .frame(width: capsuleWidth, height: Metrics.height)
                selectionPill(capsuleWidth: capsuleWidth)
                ForEach(AteTab.allCases) { tab in
                    item(tab, showsLabel: true).position(slotCentre(tab))
                }
            }
            .frame(width: capsuleWidth, height: Metrics.height, alignment: .topLeading)
            .scaleEffect(isExpanded ? 1 : 0.92, anchor: .bottomLeading)
            .offset(y: isExpanded ? 0 : Metrics.swapDrop)
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(isExpanded == false)

            ZStack {
                AteGlassSurface(shape: Circle(), shadow: .bar)
                AteTabBarItemIcon(tab: current, isCurrent: true)
            }
            .frame(width: Metrics.minimised, height: Metrics.minimised)
            .scaleEffect(isExpanded ? 0.6 : 1)
            .offset(x: Metrics.discInset, y: Metrics.discInset + (isExpanded ? Metrics.swapDrop : 0))
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            disc
                .offset(x: Metrics.discInset, y: Metrics.discInset)
                .allowsHitTesting(isExpanded == false)
                .accessibilityHidden(isExpanded)
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
    }

    private func item(_ tab: AteTab, showsLabel: Bool) -> some View {
        Button {
            onSelect(tab)
        } label: {
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
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(tab == current ? .isSelected : [])
        .accessibilityIdentifier("tabbar.\(tab.rawValue)")
    }

    private func selectionPill(capsuleWidth: CGFloat) -> some View {
        let shown = pill ?? current
        let centre = slotCentre(shown).x
        let minX = Metrics.pillInset
        let maxX = capsuleWidth - Metrics.pillInset - Metrics.pillWidth
        let x = min(max(centre - Metrics.pillWidth / 2, minX), maxX)
        return Capsule()
            .fill(AteGlassColor.selection)
            .frame(width: Metrics.pillWidth, height: Metrics.height - 2 * Metrics.pillInset)
            .offset(x: x, y: Metrics.pillInset)
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
    /// Variant B: how far the full bar drops as it goes.
    static let swapDrop: CGFloat = 14
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

/// Hides a subtree from VoiceOver when asked, and otherwise leaves its own choices alone.
private struct AteAccessibilityHiddenIf: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.accessibilityHidden(true)
        } else {
            content
        }
    }
}

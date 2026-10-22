import SwiftUI

/// **The glass header** (`lighter-header.html` B, 22 Oct) — Journal, Feed and Saved. The root's
/// title row (title leading, the glass group trailing, a control apart before it), and under it an
/// accessory (the Journal's switch, the filter's chips), as one header over the page: no ground, the
/// page scrolling under it behind the system's regular material once it is under it. Scrolling down
/// the header steps away, up to the status bar; any scroll up, or the page's top, brings it back.
///
/// The header is drawn over the page, never in the navigation bar, and the room kept for it never
/// changes while it comes and goes: build 174 hid the native bar, and the inset leaving with it
/// moved the page under the finger and read as a scroll that brought the bar straight back.
private struct AteGlassRootHeader<Apart: View, Controls: View, Accessory: View>: ViewModifier {
    let title: AteRootHeaderTitle
    let subtitle: String?
    let inline: AteInlineTitle?
    let isCollapsed: Bool
    let isHidden: Bool
    let showsApart: Bool
    let apart: Apart
    let controls: Controls
    let accessory: Accessory

    /// The header's height, title row and accessory: the room the page keeps under it.
    @State private var height: CGFloat = AteMetrics.hit
    @State private var isOverPage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: height)
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > AteHeaderGroundMetrics.showAfter
            } action: { _, isUnder in
                withAnimation(.easeOut(duration: AteHeaderGroundMetrics.switchDuration)) { isOverPage = isUnder }
            }
            .overlay(alignment: .top) { frost }
            .overlay(alignment: .top) { header }
    }

    // MARK: - The frost

    /// The system's regular material from the screen's top edge to the header's bottom, fading out
    /// just past it; the status bar's height alone while the header is away. Off at rest (build 92:
    /// at rest the page is one surface).
    private var frost: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top
            let solid = top + (isHidden ? 0 : height)
            let fade = AteGlassRootHeaderMetrics.fade
            Rectangle()
                .fill(.regularMaterial)
                .frame(height: solid + fade)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: solid / (solid + fade)),
                                .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .ignoresSafeArea(edges: .top)
        }
        .opacity(isOverPage ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - The header

    private var header: some View {
        VStack(spacing: 0) {
            titleRow
            accessory
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // Up past the status bar, as the native bar leaves; the page under it never moves.
        .offset(y: isHidden ? -(height + AteGlassRootHeaderMetrics.clearance) : 0)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(isHidden == false)
        .accessibilityHidden(isHidden)
    }

    private var titleRow: some View {
        let showsInline = isCollapsed && inline != nil
        return HStack(spacing: AteMetrics.snug) {
            // The root title and the inline one stacked, crossfading, as in the native bar.
            ZStack(alignment: .leading) {
                AteRootTitle(title: title, subtitle: subtitle)
                    .accessibilityIdentifier("root.title")
                    .opacity(showsInline ? 0 : 1)
                    .accessibilityHidden(showsInline)
                if let inline {
                    inline
                        .accessibilityIdentifier("root.inlineTitle")
                        .opacity(showsInline ? 1 : 0)
                        .accessibilityHidden(showsInline == false)
                }
            }
            .fixedSize()
            .animation(AteRootHeaderMetrics.collapse, value: showsInline)
            Spacer(minLength: 0)
            if showsApart {
                apart
                    .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            AteGlassGroup { controls }
        }
        .padding(.leading, title == .wordmark ? AteRootHeaderMetrics.wordmarkLeading : AteMetrics.gutter)
        .padding(.trailing, AteRootHeaderMetrics.trailing)
        .frame(height: AteMetrics.hit)
    }
}

/// ``SwiftUICore/View/ateRootBarHiding(_:)``. Only a finger's scroll counts — a drag or its coast —
/// and after each change the header is left alone while it moves.
private struct AteRootBarHiding: ViewModifier {
    @Binding var isHidden: Bool
    /// How far the page has moved in one direction since it last turned (down positive).
    @State private var run: CGFloat = 0
    @State private var phase: ScrollPhase = .idle
    /// No change before this: the last one is still settling.
    @State private var settling = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Reading: Equatable {
        var offset: CGFloat
        /// How far under the header the page has gone: zero at rest.
        var depth: CGFloat
        /// Past the end — the bottom's rubber band, which must not bring the header back.
        var isPastEnd: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, now in
                phase = now
                if now == .idle { run = 0 }
            }
            .onScrollGeometryChange(for: Reading.self) { geometry in
                let end = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
                return Reading(
                    offset: geometry.contentOffset.y,
                    depth: geometry.contentOffset.y + geometry.contentInsets.top,
                    isPastEnd: geometry.contentOffset.y > end
                )
            } action: { old, new in
                if new.depth < AteGlassRootHeaderMetrics.showWithin {
                    run = 0
                    set(false)
                    return
                }
                let isFinger = phase == .interacting || phase == .decelerating
                guard isFinger, Date.now >= settling, new.isPastEnd == false, old.isPastEnd == false else {
                    run = 0
                    return
                }
                let step = new.offset - old.offset
                run = (run >= 0) == (step >= 0) ? run + step : step
                if run > AteGlassRootHeaderMetrics.hideAfter, new.depth > AteGlassRootHeaderMetrics.hideBelow {
                    set(true)
                } else if run < -AteGlassRootHeaderMetrics.showAfter, phase == .interacting {
                    // Up only under the finger: the small give as a drag lets go is not a scroll up.
                    set(false)
                }
            }
    }

    private func set(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        settling = .now.addingTimeInterval(AteGlassRootHeaderMetrics.settle)
        run = 0
        withAnimation(reduceMotion ? nil : AteGlassRootHeaderMetrics.slide) { isHidden = hidden }
    }
}

enum AteGlassRootHeaderMetrics {
    /// The frost runs this far past the header's bottom, fading out, so the page meets it softly.
    static let fade: CGFloat = 14
    /// How far past the header's own height it travels to clear the status bar.
    static let clearance: CGFloat = 80
    /// The header leaves after this much scrolling down in one go…
    static let hideAfter: CGFloat = 24
    /// …only once the page is this far under it…
    static let hideBelow: CGFloat = 120
    /// …and is back after this much scrolling up, or whenever the page is this near its top.
    static let showAfter: CGFloat = 40
    static let showWithin: CGFloat = 24
    /// The header leaving or coming back.
    static let slide: Animation = .smooth(duration: 0.28)
    /// How long after the header moves before it may move again: its slide, and a little more.
    static let settle: TimeInterval = 0.45
}

extension View {
    /// Installs a tab root's **glass header** (``AteGlassRootHeader``) in place of the native bar:
    /// the same title, inline title and glass group as ``ateRootToolbar(title:subtitle:inline:isCollapsed:controls:)``,
    /// with an `accessory` under the row, the whole of it away while `isHidden`.
    func ateGlassRootHeader<Apart: View, Controls: View, Accessory: View>(
        title: AteRootHeaderTitle,
        subtitle: String? = nil,
        inline: AteInlineTitle? = nil,
        isCollapsed: Bool,
        isHidden: Bool,
        showsApart: Bool = false,
        @ViewBuilder apart: () -> Apart = { EmptyView() },
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        modifier(AteGlassRootHeader(
            title: title, subtitle: subtitle, inline: inline, isCollapsed: isCollapsed, isHidden: isHidden,
            showsApart: showsApart, apart: apart(), controls: controls(), accessory: accessory()
        ))
    }

    /// Hides a glass header while the page scrolls down and brings it back on any scroll up, or near
    /// the top — Safari's bar, and the tab bar's own minimise. Apply to the root's own `ScrollView`
    /// or `List`, beside ``ateRootCollapse(_:)``.
    func ateRootBarHiding(_ isHidden: Binding<Bool>) -> some View {
        modifier(AteRootBarHiding(isHidden: isHidden))
    }
}

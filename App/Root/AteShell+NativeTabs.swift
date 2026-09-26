import AteKit
import SwiftUI

/// **The native shell** — the `-ate-tabbar A|B` prototype of the bottom bar as iOS 26's own
/// `TabView`. Everything the custom shell does still happens (one path, one composer, the same
/// screens and routes); only the bar, and where compose lives, change.
extension AteShell {
    var tabBarStyle: AteTabBarStyle { AteTabBarStyle.current }

    /// The composer, presented over whichever shell is up.
    func composerCover(_ presentation: ComposerPresentation) -> some View {
        ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
    }

    /// A pushed page that keeps the floating bar under it. The stack's root bar is covered by the
    /// push, so the page carries its own — and tapping a tab from one pops back to that tab.
    @ViewBuilder
    func overTabBar(@ViewBuilder _ content: () -> some View) -> some View {
        if tabBarStyle.isNative {
            // The native bar is the TabView's own and stays up through the push.
            content().ateGround()
        } else {
            customOverTabBar(content)
        }
    }

    private func customOverTabBar(_ content: () -> some View) -> some View {
        ZStack(alignment: .bottom) {
            content()
            AteTabScrim()
            AteTabBar(
                selection: Binding(get: { tab }, set: { tapped in
                    guard mayOpen(tapped) else { return }
                    tab = tapped
                    path.removeAll()
                }),
                onCompose: { openComposer(.tabBar) }
            )
        }
        .ateGround()
    }

    @ViewBuilder
    var nativeShell: some View {
        let tabs = TabView(selection: nativeSelection) {
            nativeTab(.journal)
            nativeTab(.feed)
            nativeTab(.search)
            nativeTab(.you)
            if tabBarStyle == .nativeA {
                // iOS 26 has no API for an action beside the bar; the one system slot that floats a
                // separate glass circle there is the search role's. It is borrowed for `+`, and the
                // selection binding turns "selected" into "present the composer".
                Tab(value: AteTabSlot.compose, role: .search) {
                    Color.clear
                } label: {
                    Label { Text("New entry") } icon: { AteIcon.compose.templateImage() }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(AtePalette.automatic.fg)

        Group {
            if tabBarStyle == .nativeB {
                tabs.tabViewBottomAccessory {
                    AteComposeAccessory { openComposer(.tabBar) }
                }
            } else {
                tabs
            }
        }
        .fullScreenCover(item: $composing) { presentation in composerCover(presentation) }
        #if DEBUG
        .fullScreenCover(item: $debugSummary) { summary in debugSummaryScreen(summary) }
        #endif
    }

    private func nativeTab(_ tab: AteTab) -> some TabContent<AteTabSlot> {
        Tab(value: AteTabSlot.tab(tab)) {
            NavigationStack(path: path(for: tab)) {
                screen(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ateGround()
                    .toolbar(.hidden, for: .navigationBar)
                    .ateSwipeBack()
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                            .toolbar(.hidden, for: .navigationBar)
                            // The design keeps the bar only under the pages of a tab (Ratings,
                            // Suggestions); an entry, a place, a statement are pages on their own.
                            .toolbar(route.keepsTabBar ? .visible : .hidden, for: .tabBar)
                    }
            }
        } label: {
            tab.nativeLabel
        }
    }

    /// Each tab has its own stack, and the shell's one `path` is the current tab's — switching tabs
    /// clears it, exactly as the custom bar does, so no other stack can be holding anything.
    private func path(for tab: AteTab) -> Binding<[Route]> {
        Binding(
            get: { self.tab == tab ? path : [] },
            set: { next in
                guard self.tab == tab else { return }
                path = next
            }
        )
    }

    /// The custom bar's own selection (re-tap scrolls to top, a gated tab asks first), with the
    /// compose slot turned into a presentation that never becomes the selection.
    private var nativeSelection: Binding<AteTabSlot> {
        Binding(
            get: { holdsComposeSlot ? .compose : .tab(tab) },
            set: { slot in
                switch slot {
                case .tab(let tapped):
                    selection.wrappedValue = tapped
                case .compose:
                    // UIKit has already moved its bar onto the slot. Echoing the unchanged tab back
                    // is not heard, so the slot is held for one turn and then released — a real
                    // change, which puts the bar back on the tab under the composer.
                    holdsComposeSlot = true
                    openComposer(.tabBar)
                    Task { @MainActor in holdsComposeSlot = false }
                }
            }
        )
    }
}

private extension Route {
    var keepsTabBar: Bool {
        switch self {
        case .ratings, .suggestions: true
        default: false
        }
    }
}

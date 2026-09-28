import AteKit
import SwiftUI

/// **The shell's tabs** (round 5): the app's own tab bar (`AteTabBar`) over a `TabView` that only
/// holds the four stacks — its system bar is hidden on every page. Each tab owns a
/// `NavigationStack`; the shell's one `path` is always the current tab's.
///
/// The bar is laid on each tab's *root*, so a push slides it away with the root and a pop — a Back
/// tap or the finger on a swipe — brings it back in with the root, at the finger's pace, cancelled
/// with it. `+` is a plain button: it presents the composer and never touches the selection (the
/// round-4 flash was the borrowed system slot being selected for a frame, which swapped the tab
/// under the rising composer for an empty one).
extension AteShell {
    /// The composer, presented over the tabs.
    func composerCover(_ presentation: ComposerPresentation) -> some View {
        ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
    }

    var tabShell: some View {
        // Read-only: the app's bar is the only thing that changes tabs.
        TabView(selection: Binding(get: { tab }, set: { _ in })) {
            ForEach(AteTab.allCases) { tab in
                Tab(value: tab) { tabRoot(tab) } label: { Text(tab.title) }
            }
        }
        // The page's bottom safe area (the home indicator's), from layout: what the roots' bar
        // strip is measured against (`AteTabBarMetrics.rootClearance`).
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        // The bar follows the shell's tab however it changes — a tap on the bar, a new entry
        // landing on the Journal, a debug launch.
        .onChange(of: tab, initial: true) { _, now in chrome.select(now) }
        .environment(chrome)
        // One frost behind the status bar, over every tab and every pushed page — stepping aside while
        // a tab root's compact header, which brings its own, floats over the list.
        .ateStatusBarFrost(isHidden: chrome.isHeaderFloating && path.isEmpty)
        .atePhotoViewerHost() // one full-screen viewer for every photo under the shell
        .fullScreenCover(item: $composing) { presentation in composerCover(presentation) }
        #if DEBUG
        .fullScreenCover(item: $debugSummary) { summary in debugSummaryScreen(summary) }
        #endif
    }

    /// A tab's stack, its bar floating over the root's bottom edge.
    private func tabRoot(_ tab: AteTab) -> some View {
        NavigationStack(path: path(for: tab)) {
            screen(for: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The Saved shelf's Undo, on the tab's root only — above the bar.
                .overlay(alignment: .bottom) {
                    if tab == .journal {
                        SavedUndoPill(store: saved) { Task { await saveAction.undoUnsaveFromShelf() } }
                    }
                }
                // The strip the bar stands in: the inset the system bar gave the page, so every
                // list's last row still clears it (and runs under it on the way).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: AteTabBarMetrics.rootClearance(bottomInset: bottomInset))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottom) {
                    tabBar(on: tab)
                        .padding(.bottom, AteTabBarMetrics.bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .ignoresSafeArea(.keyboard)
                }
                .ateGround()
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .ateSwipeBack()
                // Which tab this root is: its scroll tracker minimises and restores the bar only
                // while it is the current one (`AteChromeTracker`).
                .environment(\.ateTabRoot, tab)
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                        // The page's own top bar (`ateNavigationBar`), no system bars, and the ground
                        // over the root and its tab bar.
                        .ateNavigationBarHost()
                }
        }
    }

    private func tabBar(on root: AteTab) -> some View {
        AteTabBar(
            chrome: chrome,
            root: root,
            onSelect: { selection.wrappedValue = $0 },
            onExpand: { chrome.expand() },
            onCompose: {
                // The `+` is a key like any other: one light tap under the finger (round 4).
                AteHaptics.key()
                openComposer(.tabBar)
            }
        )
    }

    /// Each tab has its own stack, and the shell's one `path` is the current tab's — switching tabs
    /// clears it (a tab is a place, not a layer), so no other stack can be holding anything.
    private func path(for tab: AteTab) -> Binding<[Route]> {
        Binding(
            get: { self.tab == tab ? path : [] },
            set: { next in
                guard self.tab == tab else { return }
                path = next
            }
        )
    }
}

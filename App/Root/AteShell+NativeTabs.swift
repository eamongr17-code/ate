import AteKit
import SwiftUI

/// **The shell's tab bar** — iOS 26's own `TabView`: Liquid Glass, minimised on scroll down, the
/// system's re-tap, haptics and accessibility, with compose as the glass `+` beside the bar.
/// Each tab owns a `NavigationStack`; the shell's one `path` is always the current tab's.
extension AteShell {
    /// The composer, presented over the tabs.
    func composerCover(_ presentation: ComposerPresentation) -> some View {
        ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
    }

    var tabShell: some View {
        TabView(selection: tabSelection) {
            tab(.journal)
            tab(.feed)
            tab(.search)
            tab(.you)
            // iOS 26 has no API for an action beside the bar; the one system slot that floats a
            // separate glass circle there is the search role's. It is borrowed for `+`, and the
            // selection binding turns "selected" into "present the composer" (`AteTabSlot`).
            Tab(value: AteTabSlot.compose, role: .search) {
                Color.clear
            } label: {
                Label { Text("New entry") } icon: { AteIcon.compose.templateImage() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(AtePalette.automatic.fg)
        .atePhotoViewerHost() // one full-screen viewer for every photo under the shell
        .fullScreenCover(item: $composing) { presentation in composerCover(presentation) }
        #if DEBUG
        .fullScreenCover(item: $debugSummary) { summary in debugSummaryScreen(summary) }
        #endif
    }

    private func tab(_ tab: AteTab) -> some TabContent<AteTabSlot> {
        Tab(value: AteTabSlot.tab(tab)) {
            NavigationStack(path: path(for: tab)) {
                screen(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The Saved shelf's Undo, on the tab's root only. Inside the tab, so it sits in
                    // the safe area the native bar leaves — above it, however the bar is drawn.
                    .overlay(alignment: .bottom) {
                        if tab == .journal {
                            SavedUndoPill(store: saved) { Task { await saveAction.undoUnsaveFromShelf() } }
                        }
                    }
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

    /// The shell's selection (re-tap scrolls to top, a gated tab asks first), with the compose slot
    /// turned into a presentation that never becomes the selection.
    private var tabSelection: Binding<AteTabSlot> {
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

import AteKit
import SwiftUI

/// **What the page is doing, as far as a waiting link cares** — whether the tabs are on screen, and
/// how many things are up over them (a sheet, the photo preview). Everything that covers the page
/// reports itself with ``SwiftUICore/View/ateCoversThePage()``; the tab shell reports itself with
/// ``SwiftUICore/View/ateLinkShell()``. Handed down by ``SwiftUICore/View/ateEntryLinks(_:open:)``.
@MainActor
@Observable
final class AteLinkStage {
    var covers = 0
    var isShellUp = false
}

extension EnvironmentValues {
    @Entry var ateLinkStage: AteLinkStage?
}

extension View {
    /// **Opens links into the app** — `ate://entry/<id>` — wherever the shell is. A link is held
    /// (``EntryLinkInbox``) until the shell can open it: past `Welcome` (into browsing), after the
    /// first-run handle step, once the composer, a sheet, the photo preview or the sign-in ask has
    /// gone, and only once the tabs are on screen — a push made before they are is lost. A cold
    /// start is the same path. Anything that is not one of ours is counted as unrecognised.
    func ateEntryLinks(
        _ situation: EntryLinkInbox.Situation,
        open: @escaping (_ entryID: UUID, _ browseFirst: Bool) -> Void
    ) -> some View {
        modifier(EntryLinkHost(situation: situation, open: open))
    }

    /// Marks the tab shell: a waiting link is pushed from its appearance, never before it.
    func ateLinkShell() -> some View {
        modifier(LinkShellMarker())
    }

    /// Marks something that covers the page while it is up — a waiting link waits for it to go.
    func ateCoversThePage() -> some View {
        modifier(PageCoverMarker())
    }
}

private struct EntryLinkHost: ViewModifier {
    let situation: EntryLinkInbox.Situation
    let open: (UUID, Bool) -> Void

    @State private var inbox = EntryLinkInbox()
    @State private var stage = AteLinkStage()

    /// The shell's own situation, with what only the page knows folded in.
    private var current: EntryLinkInbox.Situation {
        var current = situation
        current.isCovered = current.isCovered || stage.covers > 0
        current.isShellUp = stage.isShellUp
        return current
    }

    func body(content: Content) -> some View {
        content
            .environment(\.ateLinkStage, stage)
            .onOpenURL { url in
                guard case .entry(let entryID)? = AteLinks.parse(url) else {
                    AteTelemetry.record(LinkEvents.linkOpened(nil))
                    return
                }
                inbox.receive(entryID)
                deliver()
            }
            .onChange(of: current) { _, _ in deliver() }
    }

    private func deliver() {
        switch inbox.next(current) {
        case .wait: break
        // Browsing starts; the link is still held, and opens once the shell is up.
        case .browse: open(UUID(), true)
        case .open(let entryID): open(entryID, false)
        }
    }
}

private struct LinkShellMarker: ViewModifier {
    @Environment(\.ateLinkStage) private var stage

    func body(content: Content) -> some View {
        content
            .onAppear { stage?.isShellUp = true }
            .onDisappear { stage?.isShellUp = false }
    }
}

private struct PageCoverMarker: ViewModifier {
    @Environment(\.ateLinkStage) private var stage

    func body(content: Content) -> some View {
        content
            .onAppear { stage?.covers += 1 }
            .onDisappear {
                guard let stage else { return }
                stage.covers = max(0, stage.covers - 1)
            }
    }
}

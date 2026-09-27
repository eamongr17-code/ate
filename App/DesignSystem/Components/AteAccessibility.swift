import SwiftUI

extension View {
    /// Hides a *container* from VoiceOver when `isHidden`, and otherwise leaves what is inside it to
    /// its own choices — the frozen composer's editor and toolbar, a tab root's bar off screen.
    ///
    /// One fixed modifier chain, never a branch: a branch changes the view's identity each time it
    /// flips, which tore down and remade the composer's text view at the Post tap (losing its undo)
    /// and rebuilt the tab bar on every tab switch (QA on #85). Shown, the view is a plain `.contain`
    /// container, so its own `hidden: false` sits on the container and is not pushed down onto
    /// children that hide themselves; hidden, it is one ignored element, hidden.
    ///
    /// A single element (a leaf that already combines its children) takes `accessibilityHidden(_:)`
    /// directly — there is nothing inside it to protect.
    func ateAccessibilityHidden(_ isHidden: Bool) -> some View {
        accessibilityElement(children: isHidden ? .ignore : .contain)
            .accessibilityHidden(isHidden)
    }
}

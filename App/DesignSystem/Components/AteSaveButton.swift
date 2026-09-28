import SwiftUI

/// **The bookmark** — a save is always one dish (PRODUCT.md decision 7), and it is the same mark and the
/// same 44pt target wherever a dish can be saved: a slip's dish row, the entry page's lines, and every
/// row and card of the Feed's edition. The outline is unsaved; filled is saved. What the tap does is
/// the one ``SaveAction``, made at the shell.
///
/// Where it sits on its row — the negative margins that set the mark on the paper's edge — is the
/// row's to say, not the button's.
struct AteSaveButton: View {
    let dishName: String
    let isSaved: Bool
    var identifier = "slip.save"
    let action: () -> Void

    /// `ic("bm", 22)` in a 44 button.
    static let mark: CGFloat = 22

    var body: some View {
        Button(action: action) {
            (isSaved ? AteIcon.saved : AteIcon.save)
                .view(size: Self.mark)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? "Saved \(dishName)" : "Save \(dishName)")
        .accessibilityAddTraits(isSaved ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

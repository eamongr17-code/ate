import SwiftUI

/// **The bookmark** — the one Save. A save is always one dish (PRODUCT.md decision 7), and it is the
/// same mark and the same tap wherever a dish can be saved: a slip's dish row, the entry page's lines,
/// every dish row, ranked row, shelf card and the hero. The outline is unsaved; filled is saved. What
/// the tap does is the one ``SaveAction``, made at the shell.
///
/// Two dresses of the one control (``Style``): plain on a row, in a 44 target; or on a photo, on a
/// native Liquid Glass disc. Where it sits on its row — the negative margins that set the mark on
/// the paper's edge — is the row's to say, not the button's.
struct AteSaveButton: View {
    /// How the bookmark is dressed.
    enum Style: Equatable {
        /// On a row: the mark alone, `ic("bm", 22)` in a 44 target.
        case plain
        /// On a photo: the mark on a glass disc — a shelf card's 36 (mark 19), the hero's 44 (22).
        case glass(GlassSize)
    }

    enum GlassSize: Equatable {
        case card, hero
    }

    let dishName: String
    let isSaved: Bool
    var identifier = "slip.save"
    var style: Style = .plain
    let action: () -> Void

    /// `ic("bm", 22)` in a 44 button.
    static let mark: CGFloat = 22

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? "Saved \(dishName)" : "Save \(dishName)")
            .accessibilityAddTraits(isSaved ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var face: some View {
        let icon = isSaved ? AteIcon.saved : AteIcon.save
        switch style {
        case .plain:
            icon.view(size: Self.mark)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        case .glass(let size):
            let metrics = AteSaveButtonMetrics(size)
            icon.view(size: metrics.mark)
                .foregroundStyle(palette.fg)
                .frame(width: metrics.disc, height: metrics.disc)
                .glassEffect(.regular.interactive(), in: .circle)
                // A 36 disc still takes a 44 finger.
                .contentShape(.circle.inset(by: -metrics.hitOutset))
        }
    }
}

struct AteSaveButtonMetrics {
    let disc: CGFloat
    let mark: CGFloat

    /// How far the target reaches past the disc to make 44.
    var hitOutset: CGFloat { max(0, (AteMetrics.hit - disc) / 2) }

    init(_ size: AteSaveButton.GlassSize) {
        switch size {
        case .card: (disc, mark) = (36, 19)
        case .hero: (disc, mark) = (AteMetrics.hit, AteSaveButton.mark)
        }
    }
}

import SwiftUI

/// **The glass disc** — the one corner action: one icon in a 44pt disc of iOS 26's own Liquid Glass
/// (`.glassEffect`), never a hand-built frost. Close top left and the primary top right on every
/// sheet; a pushed page's controls; the root's trailing group is the same glass (``AteGlassGroup``).
///
/// The primary is the ink tick (the composer's Done, a sheet's commit): the same glass tinted with the
/// solid pill's colour, its glyph in the colour written on it. Muted at 40% while it cannot act yet
/// (no place attached), and stepping three dots while it posts.
struct AteGlassDisc: View {
    enum Role: Equatable {
        /// Clear glass, the glyph in the surface's ink.
        case plain
        /// The ink tick.
        case primary
    }

    let icon: AteIcon
    let label: String
    var role: Role = .plain
    var isEnabled = true
    /// The tap landed and the thing is under way: three stepping dots replace the glyph.
    var isBusy = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    AtePostingDots()
                } else {
                    icon.view(size: AteGlassDiscMetrics.glyph)
                }
            }
            .foregroundStyle(role == .primary ? palette.inverted : palette.fg)
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
            .glassEffect(glass, in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isBusy)
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? "In progress" : "")
        .accessibilityIdentifier(identifier ?? "glass.\(label.lowercased())")
    }

    private var glass: Glass {
        switch role {
        case .plain: .regular.interactive()
        case .primary: .regular.tint(palette.solid).interactive()
        }
    }
}

enum AteGlassDiscMetrics {
    /// `ic(name, 22)` in the disc.
    static let glyph: CGFloat = 22
}

/// **Posting** — three 5pt dots stepping in, one every 0.32s, then round again (`.dots`); all three
/// at once with Reduce Motion. The tick's busy face.
struct AtePostingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: PostingDotsLabel.step)) { context in
            let shown = reduceMotion ? 3 : PostingDotsLabel.dots(at: context.date)
            HStack(spacing: AtePostingDotsMetrics.gap) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: AtePostingDotsMetrics.dot, height: AtePostingDotsMetrics.dot)
                        .opacity(index < shown ? 1 : 0)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum AtePostingDotsMetrics {
    static let dot: CGFloat = 5
    static let gap: CGFloat = 4
}

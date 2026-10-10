import AteKit
import SwiftUI

/// **The handle field** — one ruled line holding `@handle`, and its one mark in a 30pt slot that
/// always keeps its space, so the field never reflows as the answer comes and goes. The mark says
/// checking, free, taken or not-a-handle and never with a line of copy:
/// - **checking** — the system's small activity indicator, muted;
/// - **free** — the green disc with its check;
/// - **taken** — a coral disc with the block mark;
/// - **not a handle** — a field-coloured disc with an ✕.
///
/// The field of the current build's handle screen, as a kit part (first run and Settings share it).
struct AteHandleField: View {
    @Binding var text: String
    let mark: HandleStatus.Mark
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteHandleFieldMetrics.gap) {
            TextField("Handle", text: $text, prompt: Text(verbatim: "@"))
                .ateText(.handleField)
                .foregroundStyle(palette.fg)
                .tint(palette.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.continue)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("handle.field")
            markView
        }
        .padding(.bottom, AteHandleFieldMetrics.gap)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.fg)
                .frame(height: AteHandleFieldMetrics.rule)
        }
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .none:
            Color.clear
                .frame(width: AteHandleFieldMetrics.disc, height: AteHandleFieldMetrics.disc)
                .accessibilityHidden(true)
        case .checking:
            AtePostingDots()
                .foregroundStyle(palette.muted)
                .frame(width: AteHandleFieldMetrics.disc, height: AteHandleFieldMetrics.disc)
                .accessibilityLabel("Checking")
        case .available:
            disc(.check, fill: AteColor.green, glyph: AteColor.ink)
                .accessibilityLabel("Available")
        case .taken:
            disc(.block, fill: AteColor.coral, glyph: AteColor.ink)
                .accessibilityLabel("Taken")
        case .malformed:
            disc(.close, fill: palette.field, glyph: palette.fg)
                .accessibilityLabel("Not a handle")
        }
    }

    private func disc(_ icon: AteIcon, fill: Color, glyph: Color) -> some View {
        icon.view(size: AteHandleFieldMetrics.glyph)
            .foregroundStyle(glyph)
            .frame(width: AteHandleFieldMetrics.disc, height: AteHandleFieldMetrics.disc)
            .background(fill, in: .circle)
            .accessibilityIdentifier("handle.mark")
    }
}

enum AteHandleFieldMetrics {
    /// `gap:10px; padding-bottom:10px; border-bottom:2px solid`.
    static let gap: CGFloat = 10
    static let rule: CGFloat = 2
    static let disc: CGFloat = 30
    static let glyph: CGFloat = 18
    /// The page around it: `left:24px; right:24px; gap:28px`, the title starting a little under the bar.
    static let pageInset: CGFloat = 24
    static let pageGap: CGFloat = 28
    static let pageTop: CGFloat = 24
}

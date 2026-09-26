import AteKit
import SwiftUI

/// **`Handle`** — "Pick a handle.", one ruled field, its mark, Continue.
///
/// The same screen twice: the last step of a first sign-in (no way back — Continue is the only way
/// on), and the Handle row in Settings (pushed, with a back arrow). The field says checking, free,
/// taken or not-a-handle with a mark in the check's slot and never with a line of copy (design
/// rule 1); Continue stays off until the mark is the green check.
struct HandleScreen: View {
    @State var model: HandleModel
    /// The handle that was written — or the unchanged one, when Continue had nothing to write.
    var onDone: (String) -> Void = { _ in }
    /// Present only when this is an edit. First run draws no back arrow.
    var onBack: (() -> Void)?

    @FocusState private var isFocused: Bool
    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack(alignment: .topLeading) {
            // `padding:120px 24px 0; gap:28px`.
            VStack(alignment: .leading, spacing: HandleScreen.gap) {
                // `.h` 44 at line-height 1 — `AteTitle`, because `Text` can only loosen a line box.
                AteTitle(text: "Pick a\nhandle.", style: .handleTitle, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                field
            }
            .padding(.horizontal, HandleScreen.inset)
            .ateContentTop(HandleScreen.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let onBack {
                // Not drawn on the artboard, which only shows first run. An edit reached from
                // Settings needs a way back that does not write, and this is Settings' own arrow in
                // Settings' own place (`padding:60px 12px 0`), so the two pages read as one branch.
                AteIconButton(icon: .back, label: "Back", size: 24, action: onBack)
                    .padding(.leading, AteMetrics.regular)
                    .ateContentTop()
            }
        }
        // `position:absolute; left:20px; right:20px; bottom:40px`.
        .overlay(alignment: .bottom) {
            AteButton(title: "Continue") {
                Task {
                    guard let handle = await model.save() else { return }
                    onDone(handle)
                }
            }
            .disabled(model.canContinue == false)
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentBottom(HandleScreen.bottom)
            .accessibilityIdentifier("handle.continue")
        }
        // Continue rides above the keyboard — the artboard draws the page without one.
        .ateGround()
        // A save that did not happen for any reason but the handle being taken: said once, and
        // Continue is still there to try again.
        .ateFailureAlert(Binding(
            get: { model.didFailToSave ? .handle : nil },
            set: { if $0 == nil { model.acknowledgeSaveFailure() } }
        ))
        .onAppear {
            isFocused = true
            #if DEBUG
            // `-ate-handle-text <text>` — types into the field, so a drive can photograph the
            // checking, taken and malformed marks on a simulator that cannot be typed into.
            if let text = UserDefaults.standard.string(forKey: "ate-handle-text") { model.type(text) }
            #endif
        }
    }

    /// `gap:10px; padding-bottom:10px; border-bottom:2px solid var(--fg)`.
    private var field: some View {
        HStack(spacing: HandleScreen.fieldGap) {
            TextField(
                "Handle",
                text: Binding(get: { model.display }, set: { model.type($0) }),
                prompt: Text(verbatim: "@")
            )
            .ateText(.handleField)
            .foregroundStyle(palette.fg)
            .tint(palette.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.continue)
            .focused($isFocused)
            .onSubmit {
                Task {
                    guard let handle = await model.save() else { return }
                    onDone(handle)
                }
            }
            .accessibilityIdentifier("handle.field")
            check
        }
        .padding(.bottom, HandleScreen.fieldGap)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.fg)
                .frame(height: HandleScreen.rule)
        }
    }

    /// **The field's one mark**, in the artboard's 30pt slot — which always holds its space, so the
    /// field never reflows as the answer comes and goes.
    ///
    /// The artboard draws one state, the green disc with its check. The other three are built from
    /// the same disc so the four read as one family and never as copy (design rule 1):
    /// - **checking** — the system's own small activity indicator, muted;
    /// - **taken** — a coral disc with the block mark: somebody has it;
    /// - **malformed** — a field-coloured disc with an ✕: this can't be a handle.
    @ViewBuilder
    private var check: some View {
        switch model.status.mark {
        case .none:
            Color.clear
                .frame(width: HandleScreen.checkDisc, height: HandleScreen.checkDisc)
                .accessibilityHidden(true)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(palette.muted)
                .frame(width: HandleScreen.checkDisc, height: HandleScreen.checkDisc)
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
        icon.view(size: HandleScreen.checkIcon)
            .foregroundStyle(glyph)
            .frame(width: HandleScreen.checkDisc, height: HandleScreen.checkDisc)
            .background(fill, in: .circle)
            .accessibilityIdentifier("handle.mark")
    }

    private static let top: CGFloat = 120
    private static let inset: CGFloat = 24
    private static let gap: CGFloat = 28
    private static let fieldGap: CGFloat = 10
    private static let rule: CGFloat = 2
    private static let checkDisc: CGFloat = 30
    private static let checkIcon: CGFloat = 18
    private static let bottom: CGFloat = 40
}

#if DEBUG
#Preview("Handle — first run") {
    HandleScreen(model: HandleModel(account: InMemoryAccountService(), current: "eamon", isFirstRun: true))
}
#endif

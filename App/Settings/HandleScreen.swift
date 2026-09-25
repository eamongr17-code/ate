import AteKit
import SwiftUI

/// **`Handle`** — "Pick a handle.", one ruled field, the green check, Continue.
///
/// The same screen twice: the last step of a first sign-in (no way back — Continue is the only way
/// on), and the Handle row in Settings (pushed, with a back arrow). The check is the artboard's only
/// state; everything the field could get wrong is made impossible to type instead (``HandleName``),
/// so there is no error line to write (design rule 1).
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
        .onAppear { isFocused = true }
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

    /// The 30pt green disc with an 18pt check — drawn for exactly one state, and holding its space
    /// in every other so the field does not reflow as the answer comes and goes.
    private var check: some View {
        AteIcon.check.view(size: HandleScreen.checkIcon)
            .foregroundStyle(AteColor.ink)
            .frame(width: HandleScreen.checkDisc, height: HandleScreen.checkDisc)
            .background(AteColor.green, in: .circle)
            .opacity(model.status.showsCheck ? 1 : 0)
            .accessibilityHidden(model.status.showsCheck == false)
            .accessibilityLabel("Available")
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

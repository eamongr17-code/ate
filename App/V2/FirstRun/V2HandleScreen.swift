import AteKit
import SwiftUI

/// **Handle** — "Pick a handle.", one ruled field and its mark, and the ink tick top right in place of
/// a Continue button: the same finish as the composer. The tick stays muted until the mark is the
/// green check, and steps its dots while the handle is written.
///
/// The same screen twice: straight after Apple on a first sign-in (no way back — the tick is the only
/// way on, and it lands on an empty Journal), and the Handle row in Settings (pushed, with the
/// system's back).
struct V2HandleScreen: View {
    @State private var model: HandleModel
    /// The handle that was written — or the unchanged one, when the tick had nothing to write.
    let onDone: (String) -> Void

    @FocusState private var isFocused: Bool

    init(model: HandleModel, onDone: @escaping (String) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.onDone = onDone
    }

    var body: some View {
        if model.isFirstRun {
            // First run is the whole screen, outside the tabs: its own bar carries the tick.
            NavigationStack { page }
        } else {
            page
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: AteHandleFieldMetrics.pageGap) {
            AteTitle(text: "Pick a\nhandle.", style: .handleTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            AteHandleField(
                text: Binding(get: { model.display }, set: { model.type($0) }),
                mark: model.status.mark,
                isFocused: $isFocused,
                onSubmit: save
            )
        }
        .padding(.horizontal, AteHandleFieldMetrics.pageInset)
        .padding(.top, AteHandleFieldMetrics.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("v2.handle")
        .ateGround()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                AteGlassDisc(
                    icon: .check,
                    label: "Done",
                    role: .primary,
                    isEnabled: model.canContinue,
                    isBusy: model.isSaving,
                    identifier: "handle.continue",
                    action: save
                )
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // A save that did not happen for any reason but the handle being taken: said once, and the
        // tick is still there to try again.
        .ateFailureAlert(Binding(
            get: { model.didFailToSave ? .handle : nil },
            set: { if $0 == nil { model.acknowledgeSaveFailure() } }
        ))
        .onAppear { isFocused = true }
    }

    private func save() {
        Task {
            guard let handle = await model.save() else { return }
            onDone(handle)
        }
    }
}

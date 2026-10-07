import AteKit
import SwiftUI

/// **The composer**, presented as a sheet by ``TabShell`` over whichever tab is up.
/// `app.isComposing = false` closes it. `app.composing` says how it was opened (origin, photos, the
/// entry being edited); open it from anywhere with `app.compose(_:)`.
///
/// One sheet, two faces: **writing** (``V2ComposerWrite``), then — once a new entry's words are
/// accepted and its receipt is in hand — **printed** (``V2ComposerPrinted``), the receipt on coral
/// inside the same sheet. An edit closes on its tick: the entry is already printed.
struct ComposerSheet: View {
    let app: AppModel

    /// What it was opened with, read once: `app.composing` is cleared the moment the sheet starts
    /// to go, and the sheet must not change under the finger on its way down.
    @State private var presentation: ComposerPresentation
    /// Set once a new entry's words are accepted: the sheet turns to the printed receipt.
    @State private var printed: V2ComposerPrinted.Handoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        _presentation = State(initialValue: app.composing ?? ComposerPresentation(origin: .tabBar))
    }

    var body: some View {
        ZStack {
            Group {
                if let companionID = presentation.respondingTo {
                    // "Ate with": the prefilled scoring face (App/V2/Notifications).
                    AteWithRespondFace(app: app, companionID: companionID, isCovered: printed != nil) { handoff in
                        withAnimation(reduceMotion ? nil : V2ComposerMotion.toPrinted) { printed = handoff }
                    }
                } else {
                    V2ComposerWrite(
                        app: app,
                        presentation: presentation,
                        isCovered: printed != nil,
                        onPrinted: { handoff in
                            withAnimation(reduceMotion ? nil : V2ComposerMotion.toPrinted) { printed = handoff }
                        }
                    )
                }
            }
            .ateAccessibilityHidden(printed != nil)
            if let printed {
                V2ComposerPrinted(app: app, handoff: printed)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // A staged photo opens full screen from inside the sheet: the shell's viewer is under it.
        .atePhotoViewerHost()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

enum V2ComposerMotion {
    /// The coral ground comes up over the words.
    static let toPrinted = Animation.easeInOut(duration: 0.25)
    /// The slider and the diet codes: snappy, never bouncy.
    static let slider = Animation.snappy(duration: 0.2)
    /// The score slide rises out of the keys.
    static var sliderRising: AnyTransition {
        .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity)
    }
}

extension Notification.Name {
    /// **An entry was written or changed from the composer, or corrected on its page** — the
    /// `EntryCard`, as the `object`. The rebuilt Journal (and any list under the sheet) puts it in
    /// place; the entry page reloads when it is its own.
    static let ateV2EntryChanged = Notification.Name("ate.v2.entryChanged")
}

extension NotificationCenter {
    @MainActor
    static func ateEntryChanged(_ card: EntryCard) {
        NotificationCenter.default.post(name: .ateV2EntryChanged, object: card)
    }
}

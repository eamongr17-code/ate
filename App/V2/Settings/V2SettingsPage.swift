import AteKit
import SwiftUI

/// **Settings and the pages that hang off it** — one route case, so the shell knows one destination
/// rather than five. The model is held here, not by the shell: a destination's body is re-evaluated
/// on every redraw, and a model built in that expression would re-read the profile each time.
struct V2SettingsPage: View {
    let page: SettingsPage
    let context: V2PageContext

    @State private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    init(page: SettingsPage, context: V2PageContext) {
        self.page = page
        self.context = context
        let services = context.services
        _model = State(initialValue: SettingsModel(
            account: services.account,
            preferences: services.preferences,
            analytics: services.analytics
        ))
    }

    var body: some View {
        switch page {
        case .root:
            V2SettingsList(model: model, context: context)
        case .handle(let current):
            V2HandleScreen(
                model: HandleModel(
                    account: context.services.account,
                    analytics: context.services.analytics,
                    current: current,
                    isFirstRun: false
                ),
                onDone: { handle in
                    // Receipts are signed with it from now on, and You reads it again.
                    if handle != current { context.app.handleChosen(handle) }
                    dismiss()
                }
            )
        case .appearance:
            V2AppearancePage(model: model)
        case .artificialIntelligence:
            V2AIPage()
        case .blocked:
            V2BlockedPeoplePage(
                store: BlockedPeopleStore(account: context.services.account, analytics: context.services.analytics)
            )
        case .kit:
            // The component kit's gallery exists in Debug and Beta builds only; the current app's
            // settings branch is where that is decided, so it is drawn by it.
            SettingsDestination(page: .kit, services: context.services)
        }
    }
}

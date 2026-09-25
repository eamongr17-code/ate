import AteKit
import SwiftUI

/// The pages of the settings branch. One `Route` case carries this, so the shell learns one new
/// destination rather than five.
enum SettingsPage: Hashable {
    /// `Settings.dc.html` itself.
    case root
    /// `Handle.dc.html`, reached from the Handle row — the same screen as first run, with a way back.
    /// Carries the handle the row was showing, so the field opens on it rather than on nothing.
    case handle(current: String?)
    /// Appearance: System / Light / Dark.
    case appearance
    /// How Ate uses AI.
    case artificialIntelligence
    /// Blocked people.
    case blocked
}

/// **The settings branch, behind one view.** The shell pushes this and nothing else, which is what
/// keeps `AteRootView` to a single new `case`.
///
/// The model is built here and held by the destination, not by the shell: a navigation
/// destination's body is re-evaluated whenever anything in the shell changes, and a model built in
/// that expression would re-read the profile on every redraw.
@MainActor
struct SettingsDestination: View {
    let page: SettingsPage
    let services: AteServices
    /// Push another settings page.
    var onOpen: (SettingsPage) -> Void = { _ in }
    /// A new handle was written. The shell signs receipts with it and You shows it.
    var onHandleChanged: (String) -> Void = { _ in }
    /// The session ended — sign out.
    var onSignedOut: () -> Void = {}
    /// The account was deleted — whose, so what it left on this phone can go too.
    var onDeleted: (UUID?) -> Void = { _ in }

    @State private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    init(
        page: SettingsPage,
        services: AteServices,
        onOpen: @escaping (SettingsPage) -> Void = { _ in },
        onHandleChanged: @escaping (String) -> Void = { _ in },
        onSignedOut: @escaping () -> Void = {},
        onDeleted: @escaping (UUID?) -> Void = { _ in }
    ) {
        self.page = page
        self.services = services
        self.onOpen = onOpen
        self.onHandleChanged = onHandleChanged
        self.onSignedOut = onSignedOut
        self.onDeleted = onDeleted
        _model = State(initialValue: SettingsModel(
            account: services.account,
            preferences: services.preferences,
            analytics: services.analytics
        ))
    }

    var body: some View {
        switch page {
        case .root:
            SettingsScreen(
                model: model,
                onOpen: onOpen,
                onSignedOut: onSignedOut,
                onDeleted: onDeleted,
                onBack: { dismiss() }
            )
        case .handle(let current):
            HandleScreen(
                model: HandleModel(
                    account: services.account,
                    analytics: services.analytics,
                    current: current,
                    isFirstRun: false
                ),
                onDone: { handle in
                    if handle != current { onHandleChanged(handle) }
                    dismiss()
                },
                onBack: { dismiss() }
            )
        case .appearance:
            AppearanceScreen(model: model, onBack: { dismiss() })
        case .artificialIntelligence:
            AIScreen(onBack: { dismiss() })
        case .blocked:
            BlockedPeopleScreen(
                store: BlockedPeopleStore(account: services.account, analytics: services.analytics),
                onBack: { dismiss() }
            )
        }
    }
}

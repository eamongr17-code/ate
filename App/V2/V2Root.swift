import AteKit
import SwiftUI

/// **The rebuilt app's root** (phase 2b): the door, the first-run handle, or the tab shell — the
/// same three places the current app has, on the native shell. Reached by `-ate-v2` or the "New
/// app" row in Settings (Debug and Beta, ``AppGeneration``); the current app is untouched beside it.
struct V2Root: View {
    @State private var app: AppModel
    /// Where the shell opens: a tab, and the composer over it (``V2Launch``).
    @State private var start: V2Launch.Start
    @Environment(\.scenePhase) private var scenePhase

    init(services: AteServices, onSessionEnded: @escaping () -> Void) {
        _app = State(initialValue: AppModel(services: services, onSessionEnded: onSessionEnded))
        _start = State(initialValue: V2Launch.start)
        AteNativeChrome.install()
    }

    var body: some View {
        Group {
            if app.owesHandle {
                V2FirstRunHandle(app: app)
            } else if app.isInside {
                TabShell(app: app, start: start)
                    .task(id: app.hasSession) { await app.loadHandle() }
            } else {
                welcome(isPrompt: false)
            }
        }
        // "The first write asks for sign-in": Welcome again, over the feed, with its link as Not Now.
        .fullScreenCover(isPresented: Bindable(app.gate).isAsking) { welcome(isPrompt: true) }
        .environment(app.gate)
        // ate://entry/<id>, on every screen the root shows — Welcome and the handle step too.
        .ateEntryLinks(app.linkSituation) { entryID, browseFirst in
            if browseFirst {
                if app.browse(isPrompt: false) { start = V2Launch.Start(tab: .feed) }
            } else {
                app.linkedEntry = entryID
            }
        }
        .task { await app.autoSignInIfRequested() }
        .onAppear { app.services.analytics(ShellEvents.newAppOpened()) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await app.drainOutbox() }
        }
    }

    private func welcome(isPrompt: Bool) -> some View {
        var debugDoor: (() async -> Void)?
        if app.services.debugSignIn != nil {
            debugDoor = { await app.signInToStaging() }
        }
        return V2WelcomeScreen(
            isPrompt: isPrompt,
            onSignIn: { await app.signInWithApple($0, nonce: $1) },
            onBrowse: {
                if app.browse(isPrompt: isPrompt) { start = V2Launch.Start(tab: .feed) }
            },
            onDebugSignIn: debugDoor,
            isBusy: app.isSigningIn
        )
    }
}

/// The first-run handle, once it knows what the account was made with — the current app's step and
/// `HandleModel`, on the rebuilt screen (``V2HandleScreen``).
private struct V2FirstRunHandle: View {
    let app: AppModel
    @State private var model: HandleModel?

    var body: some View {
        Group {
            if let model {
                V2HandleScreen(model: model) { app.handleChosen($0) }
            } else {
                Color.clear.ateGround()
            }
        }
        .task {
            guard model == nil else { return }
            let services = app.services
            let current = try? await services.account.account().username
            let made = HandleModel(
                account: services.account, analytics: services.analytics, current: current, isFirstRun: true
            )
            if let suggestion = app.firstRunName {
                let named = HandleName.sanitise(suggestion)
                if named.isEmpty == false, named != current { made.typed = named }
            }
            model = made
        }
    }
}

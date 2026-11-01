import AteKit
import SwiftUI

/// **The app's root under the environment**: the door, the first-run handle, the onboarding after it,
/// or the tab shell.
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
            } else if app.owesOnboarding {
                V2Onboarding(app: app)
            } else if app.isInside {
                TabShell(app: app, start: start)
                    .task(id: app.hasSession) {
                        await app.loadHandle()
                        await app.loadDiet()
                    }
            } else {
                welcome(isPrompt: false)
            }
        }
        // "The first write asks for sign-in": Welcome again, over the feed, with its link as Not Now.
        .fullScreenCover(isPresented: Bindable(app.gate).isAsking) { welcome(isPrompt: true) }
        .environment(app.gate)
        // https://ate.link/entry/<id> (and old ate:// links), on every screen the root shows — Welcome and the handle step too.
        .ateEntryLinks(app.linkSituation) { entryID, browseFirst in
            if browseFirst {
                if app.browse(isPrompt: false) { start = V2Launch.Start(tab: .feed) }
            } else {
                app.linkedEntry = entryID
            }
        }
        // "Ate with": the push token, the bell's count on foreground, and a tapped push opened.
        .ateWithPushes(app)
        .task { await app.autoSignInIfRequested() }
        // Anything the share extension left while the app was not running.
        .task { await app.receiveShares() }
        .onAppear { app.services.analytics(ShellEvents.newAppOpened()) }
        // Only while the app is in front: the connection back, and a minute's beat (receipt fallback).
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            // Opening the app is the likeliest moment before an entry: the rooms around the phone
            // are read now, quietly, so the place sheet opens on them. One read per half hour and
            // block (``NearbyPlaces``); never asks for the permission.
            if app.hasSession { app.services.nearbyPlaces.warm() }
            await app.keepOutboxMoving()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await app.drainOutbox() }
            Task { await app.receiveShares() }
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

/// The first-run handle, once it knows what the account was made with — `HandleModel` on
/// ``V2HandleScreen``.
private struct V2FirstRunHandle: View {
    let app: AppModel
    @State private var model: HandleModel?

    var body: some View {
        Group {
            if let model {
                V2HandleScreen(model: model) { app.handleChosen($0) }
            } else {
                AtePageLoader().ateGround()
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

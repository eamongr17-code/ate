import AteKit
import SwiftUI
import UIKit
import UserNotifications

/// **Push, the client half** ("Ate with", 0058). Three jobs and nothing else:
///
/// - **The one ask.** The system's notification prompt, the first time the person tags someone or
///   opens the notifications list — never at launch (``askOnce(trigger:services:)``).
/// - **The token.** With permission, every launch registers this phone's APNs token for whoever is
///   signed in (`register_push_token`). It fails silently: no server key exists yet, and nothing
///   about the app may wait on a push.
/// - **The tap.** A tapped push carries `companion_id`; the root opens that tag's scoring sheet
///   straight over whatever tab is up, skipping the list (``SwiftUICore/View/ateWithPushes(_:)``).
@MainActor
@Observable
final class AtePush {
    static let shared = AtePush()

    /// A tapped push's tag, waiting for the shell to be free to open it.
    var pendingTag: UUID?
    /// The token, once APNs has answered.
    @ObservationIgnored private(set) var token: String?
    /// Who the token is registered with — the signed-in session's services.
    @ObservationIgnored private var registrar: (any PushTokenRegistering)?

    private init() {}

    // MARK: - The ask

    /// The system's prompt, if it has never been answered; then the token. Already answered: only the
    /// token, if allowed. Counted once, when the person actually answers.
    func askOnce(trigger: NotificationEvents.PermissionTrigger, services: AteServices) async {
        registrar = services.pushTokens
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            services.analytics(NotificationEvents.pushPermissionResult(granted: granted, trigger: trigger))
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    // MARK: - The token

    /// Every launch with a session: re-register if the person has already said yes. Never asks.
    func registerIfPermitted(services: AteServices) async {
        registrar = services.pushTokens
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if let token { send(token) }
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    func received(deviceToken: Data) {
        let hex = APNsEnvironment.hex(deviceToken)
        token = hex
        send(hex)
    }

    /// Signing out: this phone stops receiving the person's pushes. Before the session ends, since
    /// the call needs it. Silent, like registering.
    func forgetToken() async {
        guard let token, let registrar else { return }
        try? await registrar.unregister(token: token)
    }

    private func send(_ token: String) {
        guard let registrar else { return }
        let environment = Self.environment
        // Silent and non-blocking: a failure here is never the person's problem.
        Task.detached { try? await registrar.register(token: token, environment: environment) }
    }

    /// Debug (Xcode-installed) is sandbox; Beta and Release are production — the build's own
    /// configuration, matching its `aps-environment` entitlement, whichever backend it points at.
    private static let environment: APNsEnvironment = {
        #if DEBUG
        APNsEnvironment.forBuild(isDebugBuild: true)
        #else
        APNsEnvironment.forBuild(isDebugBuild: false)
        #endif
    }()

    // MARK: - The tap

    func tapped(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["companion_id"] as? String, let companionID = UUID(uuidString: raw) else { return }
        pendingTag = companionID
    }
}

/// **The app delegate push needs** — the token comes back to a delegate, and so does a tapped push.
final class AtePushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in AtePush.shared.received(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Silent: the list and the bell work without push.
    }

    /// A push tapped from the lock screen or a banner: open its tag.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run { AtePush.shared.tapped(userInfo: userInfo) }
    }

    /// In the app: the banner still shows (the person may be anywhere), and the bell counts it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension View {
    /// **Push, at the root**: the token on every launch with a session, the bell's count on every
    /// return to the app, and a tapped push opened as soon as the shell is free — not under the
    /// sign-in ask, the handle step, or a composer already open.
    func ateWithPushes(_ app: AppModel) -> some View {
        modifier(AteWithPushes(app: app))
    }
}

private struct AteWithPushes: ViewModifier {
    let app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: app.hasSession) {
                guard app.hasSession else { return }
                await AtePush.shared.registerIfPermitted(services: app.services)
                await app.notifications.refreshCount()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, app.hasSession else { return }
                Task { await app.notifications.refreshCount() }
            }
            .onChange(of: canOpen, initial: true) { _, _ in openPending() }
            .onChange(of: AtePush.shared.pendingTag) { _, _ in openPending() }
    }

    private var canOpen: Bool {
        app.hasSession && app.owesHandle == false && app.isComposing == false && app.gate.isAsking == false
    }

    private func openPending() {
        guard canOpen, let companionID = AtePush.shared.pendingTag else { return }
        AtePush.shared.pendingTag = nil
        app.services.analytics(NotificationEvents.ateWithOpened(from: .push))
        app.compose(.respond(to: companionID))
    }
}

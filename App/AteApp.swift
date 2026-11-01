import AteKit
import Sentry
import SwiftUI
import TelemetryDeck

@main
struct AteApp: App {
    /// Resolved once at launch. Held as a `Result` so a misconfigured checkout still boots and
    /// shows what's missing instead of crashing on a force-unwrap.
    private let environment: Result<AteEnvironment, Error>
    /// Push needs an app delegate: the APNs token and a tapped notification come back to one.
    @UIApplicationDelegateAdaptor(AtePushDelegate.self) private var pushDelegate

    init() {
        let environment = Result { try AteEnvironment.resolve(bundle: .main) }
        self.environment = environment

        if case .success(let environment) = environment {
            AteApp.startObservability(environment)
        }
        AteTips.configure()
    }

    var body: some Scene {
        WindowGroup {
            AteRootView(environment: environment)
                .ateLaunchMoment()
        }
    }

    /// Observability is wired before any feature exists — the legacy build shipped 78 updates blind.
    private static func startObservability(_ environment: AteEnvironment) {
        if let dsn = environment.sentryDSN, !isSimulatorOrTestRun {
            SentrySDK.start { options in
                options.dsn = dsn
                options.environment = environment.name.rawValue
                options.enableAutoSessionTracking = true
                #if DEBUG
                options.debug = false
                options.tracesSampleRate = 1.0
                #else
                options.tracesSampleRate = 0.2
                #endif
            }
            // Handled faults (a journal that won't load, an entry the server refused), not only crashes.
            ErrorReporting.install { error, place in
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: place, key: "where")
                }
            }
        }

        if let appID = environment.telemetryDeckAppID {
            let config = TelemetryDeck.Config(appID: appID)
            config.defaultSignalPrefix = "Ate."
            TelemetryDeck.initialize(config: config)
            TelemetryDeck.signal("app_launched", parameters: ["environment": environment.name.rawValue])
        }
    }

    /// CI builds and tests on the simulator; its crashes are not users' and filled Sentry with noise.
    private static var isSimulatorOrTestRun: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #endif
    }
}

import AteKit
import Sentry
import SwiftUI
import TelemetryDeck

@main
struct AteApp: App {
    /// Resolved once at launch. Held as a `Result` so a misconfigured checkout still boots and
    /// shows what's missing instead of crashing on a force-unwrap.
    private let environment: Result<AteEnvironment, Error>

    init() {
        let environment = Result { try AteEnvironment.resolve(bundle: .main) }
        self.environment = environment

        if case .success(let environment) = environment {
            AteApp.startObservability(environment)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
        }
    }

    /// Observability is wired before any feature exists — the legacy build shipped 78 updates blind.
    private static func startObservability(_ environment: AteEnvironment) {
        if let dsn = environment.sentryDSN {
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
        }

        if let appID = environment.telemetryDeckAppID {
            let config = TelemetryDeck.Config(appID: appID)
            config.defaultSignalPrefix = "Ate."
            TelemetryDeck.initialize(config: config)
            TelemetryDeck.signal("app_launched", parameters: ["environment": environment.name.rawValue])
        }
    }
}

import Foundation

// MARK: - Config plumbing

/// A flat source of string configuration values. The app feeds this from `Bundle.main`
/// (populated at build time from `Config/Secrets.xcconfig` via Info.plist); tests feed a dictionary.
public protocol ConfigValueProvider: Sendable {
    func string(forKey key: String) -> String?
}

/// Snapshot of a bundle's Info.plist string values. Snapshotting keeps the provider `Sendable`
/// (`Bundle` is not) and makes reads cheap.
public struct BundleConfigProvider: ConfigValueProvider {
    private let values: [String: String]

    public init(bundle: Bundle) {
        var snapshot: [String: String] = [:]
        for (key, value) in bundle.infoDictionary ?? [:] {
            if let string = value as? String { snapshot[key] = string }
        }
        self.values = snapshot
    }

    public func string(forKey key: String) -> String? { values[key] }
}

/// In-memory provider — the test / preview seam.
public struct DictionaryConfigProvider: ConfigValueProvider {
    private let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public func string(forKey key: String) -> String? { values[key] }
}

// MARK: - Environment

/// Which Supabase project the running build talks to. Debug → staging, Release → production.
public enum AteEnvironmentName: String, Sendable, CaseIterable, Codable {
    case staging
    case production

    /// Human-facing label (skeleton screen, debug menus, telemetry dimension).
    public var displayName: String {
        switch self {
        case .staging: "Staging"
        case .production: "Production"
        }
    }

    /// Lenient parse of the `ATE_ENVIRONMENT` build setting — case- and whitespace-insensitive,
    /// with `prod`/`stage` accepted as aliases. Unknown values fail rather than silently
    /// defaulting to production (rule 5: environments are law).
    public init?(configValue raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "staging", "stage", "dev", "development": self = .staging
        case "production", "prod", "release": self = .production
        default: return nil
        }
    }
}

/// The resolved runtime configuration for this build. Values originate in
/// `Config/Secrets.xcconfig` → `Config/{Debug,Release}.xcconfig` → Info.plist → here.
public struct AteEnvironment: Sendable, Equatable {
    public static let environmentKey = "ATE_ENVIRONMENT"
    public static let supabaseURLKey = "SUPABASE_URL"
    public static let supabaseKeyKey = "SUPABASE_KEY"
    public static let sentryDSNKey = "SENTRY_DSN"
    public static let telemetryDeckAppIDKey = "TELEMETRYDECK_APP_ID"

    public let name: AteEnvironmentName
    public let supabaseURL: URL
    public let supabaseKey: String
    /// Optional so a developer with an unfilled `Secrets.xcconfig` still gets a running app.
    public let sentryDSN: String?
    public let telemetryDeckAppID: String?

    public init(
        name: AteEnvironmentName,
        supabaseURL: URL,
        supabaseKey: String,
        sentryDSN: String? = nil,
        telemetryDeckAppID: String? = nil
    ) {
        self.name = name
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.sentryDSN = sentryDSN
        self.telemetryDeckAppID = telemetryDeckAppID
    }

    public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case missing(key: String)
        case unreadableEnvironment(raw: String)
        case malformedURL(key: String, raw: String)

        public var description: String {
            switch self {
            case .missing(let key):
                "Missing configuration value \"\(key)\". Copy Config/Secrets.example.xcconfig to Config/Secrets.xcconfig and fill it in."
            case .unreadableEnvironment(let raw):
                "Unrecognised \(AteEnvironment.environmentKey) value \"\(raw)\" — expected staging or production."
            case .malformedURL(let key, let raw):
                "Configuration value \"\(key)\" is not a valid URL: \"\(raw)\"."
            }
        }
    }

    /// Marker for a value the xcconfig template ships unfilled. Treated as absent everywhere, so an
    /// unfilled key surfaces as a loud configuration error instead of quietly reaching a real backend
    /// with garbage credentials.
    static let placeholderPrefix = "REPLACE_ME"

    /// Pure resolution from any config source. The whole environment story is testable through this.
    public static func resolve(from provider: some ConfigValueProvider) throws -> AteEnvironment {
        func value(_ key: String) -> String? {
            guard let raw = provider.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  !raw.hasPrefix(placeholderPrefix) else { return nil }
            return raw
        }

        func require(_ key: String) throws -> String {
            guard let value = value(key) else { throw ConfigurationError.missing(key: key) }
            return value
        }

        func optional(_ key: String) -> String? { value(key) }

        let rawName = try require(environmentKey)
        guard let name = AteEnvironmentName(configValue: rawName) else {
            throw ConfigurationError.unreadableEnvironment(raw: rawName)
        }

        let rawURL = try require(supabaseURLKey)
        guard let url = URL(string: rawURL), url.scheme != nil, url.host() != nil else {
            throw ConfigurationError.malformedURL(key: supabaseURLKey, raw: rawURL)
        }

        return AteEnvironment(
            name: name,
            supabaseURL: url,
            supabaseKey: try require(supabaseKeyKey),
            sentryDSN: optional(sentryDSNKey),
            telemetryDeckAppID: optional(telemetryDeckAppIDKey)
        )
    }

    /// Convenience for the app target.
    public static func resolve(bundle: Bundle) throws -> AteEnvironment {
        try resolve(from: BundleConfigProvider(bundle: bundle))
    }
}

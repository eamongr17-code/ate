import Foundation
import Testing
@testable import AteKit

@Suite("AteEnvironment")
struct AteEnvironmentTests {
    private static let staging: [String: String] = [
        AteEnvironment.environmentKey: "staging",
        AteEnvironment.supabaseURLKey: "https://cvoitgoaosofkougmarn.supabase.co",
        AteEnvironment.supabaseKeyKey: "sb_publishable_example",
        AteEnvironment.sentryDSNKey: "https://key@o1.ingest.us.sentry.io/2",
        AteEnvironment.telemetryDeckAppIDKey: "63681364-7965-415E-B0AE-B91986E0A885"
    ]

    @Test("resolves a complete staging configuration")
    func resolvesStaging() throws {
        let env = try AteEnvironment.resolve(from: DictionaryConfigProvider(Self.staging))
        #expect(env.name == .staging)
        #expect(env.supabaseURL.host() == "cvoitgoaosofkougmarn.supabase.co")
        #expect(env.supabaseKey == "sb_publishable_example")
        #expect(env.sentryDSN != nil)
        #expect(env.telemetryDeckAppID != nil)
    }

    @Test("unfilled placeholder secrets resolve to nil rather than garbage")
    func placeholdersBecomeNil() throws {
        var values = Self.staging
        values[AteEnvironment.sentryDSNKey] = "REPLACE_ME"
        values[AteEnvironment.telemetryDeckAppIDKey] = ""
        let env = try AteEnvironment.resolve(from: DictionaryConfigProvider(values))
        #expect(env.sentryDSN == nil)
        #expect(env.telemetryDeckAppID == nil)
    }

    @Test("an unfilled REPLACE_ME secret fails rather than reaching a backend with garbage")
    func placeholderRequiredValueFails() {
        var values = Self.staging
        values[AteEnvironment.supabaseKeyKey] = "REPLACE_ME_WHEN_PROD_RESTORED"
        #expect(throws: AteEnvironment.ConfigurationError.missing(key: AteEnvironment.supabaseKeyKey)) {
            _ = try AteEnvironment.resolve(from: DictionaryConfigProvider(values))
        }
    }

    @Test("a missing required value is reported by key")
    func missingKey() {
        var values = Self.staging
        values.removeValue(forKey: AteEnvironment.supabaseKeyKey)
        #expect(throws: AteEnvironment.ConfigurationError.missing(key: AteEnvironment.supabaseKeyKey)) {
            _ = try AteEnvironment.resolve(from: DictionaryConfigProvider(values))
        }
    }

    @Test("an unknown environment name fails instead of defaulting to production")
    func unknownEnvironmentFails() {
        var values = Self.staging
        values[AteEnvironment.environmentKey] = "wherever"
        #expect(throws: AteEnvironment.ConfigurationError.unreadableEnvironment(raw: "wherever")) {
            _ = try AteEnvironment.resolve(from: DictionaryConfigProvider(values))
        }
    }

    @Test("environment names parse leniently", arguments: [
        ("staging", AteEnvironmentName.staging),
        ("  Staging ", .staging),
        ("PROD", .production),
        ("production", .production)
    ])
    func parsesNames(raw: String, expected: AteEnvironmentName) {
        #expect(AteEnvironmentName(configValue: raw) == expected)
    }
}

import Foundation
import Supabase

@testable import AteKit

/// The staging connection the contract smoke suite (``ContractSmokeTests``) uses.
///
/// STAGING and nothing else — Debug/test paths never touch prod (rule 5). Credentials are the
/// committed publishable staging key (RLS is the security boundary) and the dedicated contract-test
/// account `ci@ate.test`, made by `supabase/staging-seed/seed.mjs --ci-account` and registered in its
/// provenance registry. Never `eamon@ate.test`: that login holds Eamon's real staging entries and is
/// what the simulator drives use. CI only ever READS as this account.
///
/// Opt-in: set `ATE_CONTRACT_TESTS=1` to run (CI does on backend PRs and on main; plain `swift test`
/// skips it so unit tests stay green through a staging outage).
enum StagingContract {
    static func environmentValue(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var url: URL {
        URL(string: environmentValue("SUPABASE_URL_STAGING") ?? "https://cvoitgoaosofkougmarn.supabase.co")!
    }
    static var key: String {
        environmentValue("SUPABASE_KEY_STAGING") ?? "sb_publishable_sMRFIanM38nujCu5o16Jeg_CWnDriNg"
    }
    static var email: String { environmentValue("ATE_STAGING_EMAIL") ?? "ci@ate.test" }
    static var password: String { environmentValue("ATE_STAGING_PASSWORD") ?? "atedemo123" }

    static var isEnabled: Bool { environmentValue("ATE_CONTRACT_TESTS") != nil }

    /// Session storage that lives and dies with the test run — the default is the Keychain, which
    /// a CI runner's test process has no business writing to.
    final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func store(key: String, value: Data) throws {
            lock.withLock { values[key] = value }
        }
        func retrieve(key: String) throws -> Data? {
            lock.withLock { values[key] }
        }
        func remove(key: String) throws {
            lock.withLock { _ = values.removeValue(forKey: key) }
        }
    }

    static func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: EphemeralAuthStorage(),
                    autoRefreshToken: false
                )
            )
        )
    }

    /// One signed-in client shared by the suite — sign-in is the slow part.
    actor Backend {
        static let shared = Backend()
        private var cached: AteAPIClient?

        func client() async throws -> AteAPIClient {
            if let cached { return cached }
            let supabase = makeClient()
            try await supabase.auth.signIn(email: email, password: password)
            let client = AteAPIClient(supabase: supabase)
            cached = client
            return client
        }
    }
}

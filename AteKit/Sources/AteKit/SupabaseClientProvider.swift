import Foundation
import Supabase

/// The single place a `SupabaseClient` is constructed. API clients take a client via init
/// (the protocol seam) rather than reaching for a global; this provider just builds it from
/// the resolved environment so no call site ever hardcodes a URL or key.
///
/// The session is kept in ``SharedSessionStorage``: the app group's keychain, so the share extension
/// is signed in whenever the app is, with the old private item migrated on first read.
public enum SupabaseClientProvider {
    public static func make(environment: AteEnvironment) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: environment.supabaseURL,
            supabaseKey: environment.supabaseKey,
            options: SupabaseClientOptions(auth: .init(storage: SharedSessionStorage.standard))
        )
    }
}

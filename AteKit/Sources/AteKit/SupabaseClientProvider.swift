import Foundation
import Supabase

/// The single place a `SupabaseClient` is constructed. API clients take a client via init
/// (the protocol seam) rather than reaching for a global; this provider just builds it from
/// the resolved environment so no call site ever hardcodes a URL or key.
public enum SupabaseClientProvider {
    public static func make(environment: AteEnvironment) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: environment.supabaseURL,
            supabaseKey: environment.supabaseKey
        )
    }
}

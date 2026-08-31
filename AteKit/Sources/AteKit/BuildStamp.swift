import Foundation

/// A trivial pure value — the one thing the walking skeleton renders. It exists to prove the
/// rig end to end: AteKit compiles, the app can call into it, and Swift Testing runs against it.
public struct BuildStamp: Sendable, Equatable {
    public let environment: AteEnvironmentName

    public init(environment: AteEnvironmentName) {
        self.environment = environment
    }

    /// e.g. "Staging · Supabase cvoitgoaosofkougmarn"
    public func summary(supabaseHost: String?) -> String {
        guard let project = supabaseHost?.split(separator: ".").first, !project.isEmpty else {
            return environment.displayName
        }
        return "\(environment.displayName) · Supabase \(project)"
    }
}

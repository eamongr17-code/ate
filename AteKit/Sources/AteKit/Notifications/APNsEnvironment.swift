import Foundation

/// **Which APNs host a token belongs to** — from the build configuration, never from the backend it
/// points at: an Xcode-installed Debug build is `sandbox`; Beta (TestFlight, pointed at staging) and
/// Release are `production`. The `aps-environment` entitlement follows the same split
/// (`ATE_APS_ENVIRONMENT` in the xcconfigs), so the token and the host always agree.
public enum APNsEnvironment: String, Sendable, Hashable {
    case sandbox
    case production

    /// `isDebugBuild`: the Debug configuration (`#if DEBUG` at the call site).
    public static func forBuild(isDebugBuild: Bool) -> APNsEnvironment {
        isDebugBuild ? .sandbox : .production
    }

    /// The device token as the register RPC takes it: lowercase hex.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

/// **Which APNs host a token belongs to** — read from the build's own `aps-environment`, never from
/// Debug or Release: an Xcode-installed build is `sandbox`, TestFlight and the App Store are
/// `production`, whichever backend the build points at (integration-design, Ate with).
public enum APNsEnvironment: String, Sendable, Hashable {
    case sandbox
    case production

    /// From the text of `embedded.mobileprovision` (a signed plist, read as Latin-1). No profile at
    /// all is the App Store, which strips it: production. A profile without the key cannot receive
    /// pushes; it is called sandbox, the harmless guess.
    public static func from(provisioningProfile text: String?, isSimulator: Bool = false) -> APNsEnvironment {
        if isSimulator { return .sandbox }
        guard let text else { return .production }
        guard let key = text.range(of: "<key>aps-environment</key>") else { return .sandbox }
        let rest = text[key.upperBound...]
        guard let open = rest.range(of: "<string>"),
              let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex) else { return .sandbox }
        let value = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "production" ? .production : .sandbox
    }

    /// The device token as the register RPC takes it: lowercase hex.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

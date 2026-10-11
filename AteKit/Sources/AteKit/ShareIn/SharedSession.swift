import Foundation
import Supabase

/// **The app group the app and its share extension share** — one identifier, registered on both
/// targets' entitlements (`Config/Ate.entitlements`, `Config/ShareExtension.entitlements`).
public enum AteAppGroup {
    public static let identifier = "group.com.eamongracias.ate"
}

/// **One sign-in, seen by the app and the share extension.**
///
/// supabase-swift keeps the session in the keychain under its own service, in the app's private
/// access group, where an extension cannot read it. The session now lives in the app group's access
/// group (an app group is a keychain access group on iOS) under Ate's own service, so both targets
/// read the same item — a refresh made by either is the other's next read.
///
/// **Migration, lazily and in both directions safe:** a read that finds nothing shared looks in the
/// old place, and a session found there is copied across and only then removed — so a tester signed
/// in before this build stays signed in. If the shared store refuses (a build signed without the app
/// group), everything stays where it was and the app works exactly as it did; only the extension
/// cannot see the session.
public struct SharedSessionStorage: AuthLocalStorage {
    private let shared: any AuthLocalStorage
    private let legacy: any AuthLocalStorage

    public init(shared: any AuthLocalStorage, legacy: any AuthLocalStorage) {
        self.shared = shared
        self.legacy = legacy
    }

    public func store(key: String, value: Data) throws {
        do {
            try shared.store(key: key, value: value)
            try? legacy.remove(key: key)
        } catch {
            try legacy.store(key: key, value: value)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        if let data = try? shared.retrieve(key: key) { return data }
        guard let data = try? legacy.retrieve(key: key) else { return nil }
        if (try? shared.store(key: key, value: data)) != nil {
            try? legacy.remove(key: key)
        }
        return data
    }

    public func remove(key: String) throws {
        try? shared.remove(key: key)
        try? legacy.remove(key: key)
    }
}

#if canImport(Security) && !os(Linux)
extension SharedSessionStorage {
    /// The keychain service the shared session is kept under. Not supabase-swift's own
    /// (`supabase.gotrue.swift`): a query for the old item can then never match the new one, so the
    /// migration's remove cannot take the shared copy with it.
    static let sharedService = "com.eamongracias.ate.session"

    /// The app's and the extension's store: the app group's keychain, the old private one behind it.
    public static let standard = SharedSessionStorage(
        shared: KeychainLocalStorage(service: sharedService, accessGroup: AteAppGroup.identifier),
        legacy: KeychainLocalStorage()
    )
}
#endif

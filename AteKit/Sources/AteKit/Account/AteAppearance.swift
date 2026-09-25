import Foundation

/// **Which of the two grounds the app is painted on** — `Settings.dc.html`'s Appearance row.
///
/// The design has exactly two palettes (linen and ink, `docs/DESIGN.md`), so this is a three-way
/// choice and not a theme engine: follow the phone, or pin one of the two.
public enum AteAppearance: String, Sendable, Equatable, CaseIterable, Codable {
    case system
    case light
    case dark

    /// The value in the Appearance row of Settings, and the row's own name on the page it opens.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// **A preference that outlives the launch, and is read by more than one screen.**
///
/// Two of them, and they are unrelated to each other — which is the point: this is the app's
/// small bag of local state, not a settings framework. Each says where it lives and why it is not
/// on the server.
///
/// `@Observable` and `@MainActor` because the appearance is read in a view body (the root applies
/// it) and must repaint the moment Settings changes it.
@MainActor
@Observable
public final class AtePreferences {
    /// The one everything shares. A singleton because the root view, Settings and the composer all
    /// have to be looking at the same object for a change in one to be true in the others.
    public static let standard = AtePreferences(store: UserDefaultsStore())

    @ObservationIgnored private let store: any AteKeyValueStore

    public init(store: any AteKeyValueStore) {
        self.store = store
        self.appearance = AteAppearance(rawValue: store.value(forKey: Key.appearance) ?? "") ?? .system
        self.pendingHandleUserID = store.value(forKey: Key.pendingHandleUserID).flatMap(UUID.init(uuidString:))
    }

    /// System / Light / Dark. Applied at the root, so Welcome and every sheet follow it too.
    public var appearance: AteAppearance {
        didSet {
            guard appearance != oldValue else { return }
            store.setValue(appearance.rawValue, forKey: Key.appearance)
        }
    }

    /// Who still owes us a handle.
    ///
    /// Apple returns a person's name and email **only on the very first authorization** for an
    /// Apple ID / app pair, which is the one honest client-side signal for "this is a new account";
    /// the server cannot help, because `handle_new_user` gives every sign-up a derived handle, so a
    /// profile row exists either way and there is nothing to test for. Writing the id down here is
    /// what makes the step survive a first run that was killed on the handle screen — without it,
    /// the second launch would sail past with a machine-made handle nobody chose.
    public var pendingHandleUserID: UUID? {
        didSet {
            guard pendingHandleUserID != oldValue else { return }
            store.setValue(pendingHandleUserID?.uuidString, forKey: Key.pendingHandleUserID)
        }
    }

    private enum Key {
        static let appearance = "ate.appearance"
        static let pendingHandleUserID = "ate.pendingHandleUserID"
    }
}

/// The one thing ``AtePreferences`` needs from storage. A seam, so the model is tested against a
/// dictionary rather than against whatever the last test run left in `UserDefaults`.
public protocol AteKeyValueStore: AnyObject, Sendable {
    func value(forKey key: String) -> String?
    func setValue(_ value: String?, forKey key: String)
}

/// `UserDefaults`, behind the seam.
public final class UserDefaultsStore: AteKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value(forKey key: String) -> String? { defaults.string(forKey: key) }

    public func setValue(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// A dictionary, behind the same seam — previews and tests.
public final class InMemoryKeyValueStore: AteKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func value(forKey key: String) -> String? { lock.withLock { values[key] } }

    public func setValue(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

import Foundation

/// **Settings → This iPhone** — the four things iOS decides for Ate on this phone, not on the
/// account. Each row says what iOS currently allows and opens Ate's page in the Settings app, the
/// only place any of them can be changed once asked (`design/rebuild/settings-redesign.html`).
public enum DevicePermission: String, CaseIterable, Sendable {
    case notifications
    /// The camera roll: suggestions and the composer's photos.
    case photos
    /// Nearby places in the place picker.
    case location
    case camera

    /// The row's name.
    public var title: String {
        switch self {
        case .notifications: "Notifications"
        case .photos: "Photos"
        case .location: "Location"
        case .camera: "Camera"
        }
    }
}

/// What iOS has said, in the words the row shows on its right. The app maps each framework's own
/// status onto these, so the words live in one place and are tested.
public enum DevicePermissionState: String, Sendable, CaseIterable {
    /// iOS has never asked.
    case notAsked = "not_asked"
    case on
    case off
    /// Photos: the whole library.
    case allPhotos = "all_photos"
    /// Photos: the ones the person picked.
    case limited
    /// Location: while Ate is open.
    case whileUsing = "while_using"
    case always

    public var title: String {
        switch self {
        case .notAsked: "Not set"
        case .on: "On"
        case .off: "Off"
        case .allPhotos: "All photos"
        case .limited: "Limited"
        case .whileUsing: "While using"
        case .always: "Always"
        }
    }
}

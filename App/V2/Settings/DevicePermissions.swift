import AVFoundation
import AteKit
import CoreLocation
import Photos
import SwiftUI
import UserNotifications

/// **Settings → This iPhone** — what iOS currently allows Ate, read from each framework and said in
/// ``DevicePermissionState``'s words. Read when Settings appears and again whenever the app comes
/// back to the front, because the only place to change any of these is the Settings app.
@MainActor
@Observable
final class DevicePermissions {
    private(set) var states: [DevicePermission: DevicePermissionState] = [:]

    func state(of permission: DevicePermission) -> DevicePermissionState {
        states[permission] ?? .notAsked
    }

    func refresh() async {
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        states = [
            .notifications: Self.state(notifications),
            .photos: Self.state(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
            .location: Self.state(CLLocationManager().authorizationStatus),
            .camera: Self.state(AVCaptureDevice.authorizationStatus(for: .video))
        ]
    }

    /// The row was tapped. Notifications that iOS has never asked about have no page in the Settings
    /// app yet, so the system asks here instead; everything else opens Ate's own page there.
    func open(_ permission: DevicePermission, services: AteServices) async {
        let state = state(of: permission)
        services.analytics(AccountEvents.permissionOpened(permission, state: state))
        if permission == .notifications, state == .notAsked {
            await AtePush.shared.askOnce(trigger: .settings, services: services)
            await refresh()
            return
        }
        let page = permission == .notifications
            ? UIApplication.openNotificationSettingsURLString
            : UIApplication.openSettingsURLString
        guard let url = URL(string: page) else { return }
        _ = await UIApplication.shared.open(url)
    }

    // MARK: - Each framework's words, in the row's

    private static func state(_ status: UNAuthorizationStatus) -> DevicePermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorized, .provisional, .ephemeral: .on
        default: .off
        }
    }

    private static func state(_ status: PHAuthorizationStatus) -> DevicePermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .allPhotos
        case .limited: .limited
        default: .off
        }
    }

    private static func state(_ status: CLAuthorizationStatus) -> DevicePermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorizedWhenInUse: .whileUsing
        case .authorizedAlways: .always
        default: .off
        }
    }

    private static func state(_ status: AVAuthorizationStatus) -> DevicePermissionState {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .on
        default: .off
        }
    }
}

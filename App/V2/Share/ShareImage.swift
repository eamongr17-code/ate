import AteKit
import SwiftUI
import UIKit

/// **Instagram Stories** — the receipt as a sticker in IG's story editor.
///
/// Meta's documented contract: the PNG on `UIPasteboard` under `com.instagram.sharedSticker.*`, with
/// the background colours beside it, then the `instagram-stories` share URL carrying the Facebook
/// App ID. Offered only when that id is configured (`ATE_FACEBOOK_APP_ID`, one xcconfig key) and the
/// phone has Instagram — otherwise the option simply is not in the sheet.
enum InstagramStories {
    static let scheme = "instagram-stories"
    /// The receipt's ground — the coral the card stands on.
    static let groundHex = AteColor.coralHex

    /// The Facebook App ID, from Info.plist. Empty until Eamon creates one.
    static var appID: String {
        (Bundle.main.object(forInfoDictionaryKey: "ATE_FACEBOOK_APP_ID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var shareURL: URL? {
        guard appID.isEmpty == false else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "source_application", value: appID)]
        return components.url
    }

    @MainActor
    static var isAvailable: Bool {
        guard let url = shareURL else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// The pasteboard items, expiring after five minutes as Meta recommends. With a `background` the
    /// photo fills the story and the sticker floats on it; without one the story is the coral ground.
    @MainActor
    static func share(sticker: UIImage, background: UIImage? = nil) -> Bool {
        guard let url = shareURL, let png = sticker.pngData() else { return false }
        var items: [String: Any] = ["com.instagram.sharedSticker.stickerImage": png]
        if let background, let jpeg = background.jpegData(compressionQuality: 0.92) {
            items["com.instagram.sharedSticker.backgroundImage"] = jpeg
        } else {
            items["com.instagram.sharedSticker.backgroundTopColor"] = groundHex
            items["com.instagram.sharedSticker.backgroundBottomColor"] = groundHex
        }
        UIPasteboard.general.setItems([items], options: [.expirationDate: Date().addingTimeInterval(5 * 60)])
        UIApplication.shared.open(url)
        return true
    }
}

/// The "Instagram Stories" row in the system share sheet — an app activity, so the choice sits
/// where every other destination does and no new control is drawn.
final class InstagramStoriesActivity: UIActivity {
    private let sticker: UIImage

    init(sticker: UIImage) {
        self.sticker = sticker
        super.init()
    }

    override static var activityCategory: UIActivity.Category { .share }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityTitle: String? { "Instagram Stories" }
    override var activityImage: UIImage? { MainActor.assumeIsolated { Self.icon } }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        let sticker = self.sticker
        let didOpen = MainActor.assumeIsolated { InstagramStories.share(sticker: sticker) }
        activityDidFinish(didOpen)
    }

    static let type = UIActivity.ActivityType("app.ate.instagram-stories")

    /// The app's own camera line icon — never an SF Symbol, and not Meta's mark.
    @MainActor
    private static var icon: UIImage? {
        let renderer = ImageRenderer(content: AteIcon.camera.view(size: 30).foregroundStyle(.black))
        renderer.scale = 3
        return renderer.uiImage?.withRenderingMode(.alwaysTemplate)
    }
}

/// The system share sheet, given an already-rendered image.
///
/// A `UIViewControllerRepresentable` rather than SwiftUI's `ShareLink` because the thing being shared
/// is made at the moment of sharing, not held in the view's state — and because the activity
/// controller is the only way to be sure the image (not a URL, not a description) is what travels.
struct ShareSheet: UIViewControllerRepresentable {
    /// Whatever is being sent: the share card, or a link to a profile.
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    /// Instagram Stories, when it can be offered.
    var sticker: UIImage?
    /// Called once the picture has actually left, with where it went.
    var onShared: ((ShareDestination) -> Void)?

    init(image: UIImage) {
        self.items = [image]
    }

    /// A rendered share card: the system destinations, plus Instagram Stories when it is set up.
    init(sending: ShareSender.Sending, onShared: @escaping (ShareDestination) -> Void) {
        self.items = sending.items ?? [sending.image]
        self.sticker = sending.sticker
        self.onShared = onShared
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var activities: [UIActivity] = []
        if let sticker, InstagramStories.isAvailable {
            activities.append(InstagramStoriesActivity(sticker: sticker))
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: activities)
        let onShared = onShared
        controller.completionWithItemsHandler = { type, completed, _, _ in
            guard completed else { return }
            onShared?(type == InstagramStoriesActivity.type ? .instagramStories : .system)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

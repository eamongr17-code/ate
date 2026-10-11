import AteKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// **Share to Ate's principal class** (`NSExtensionPrincipalClass`). Presented over the other app
/// full screen and clear, so the card can rise from the bottom over it as the mockup draws it; the
/// card itself is SwiftUI (``ShareCardScreen``) in a hosting controller.
///
/// It builds the extension's few services against the same environment as the app (Debug and Beta
/// on STAGING), reads the shared link out of the extension's input, and finishes the request when
/// the card is closed or has saved.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let services = ShareServices.make()
        let model = services.model()
        let screen = ShareCardScreen(model: model, places: services.places) { [weak self] saved in
            self?.finish(saved: saved)
        }
        let host = UIHostingController(rootView: screen)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task {
            let shared = await SharedInput.read(items)
            await model.start(link: shared.link, text: shared.text)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AteScreen.window = view.window
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if AteScreen.window == nil { AteScreen.window = view.window }
    }

    /// Saved: the request completes. Closed: it is cancelled, as the system's own Cancel would.
    private func finish(saved: Bool) {
        if saved {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}

/// What the share sheet handed over: the first https link, and any words that came with it.
struct SharedInput: Sendable {
    var link: URL?
    var text: String?

    /// Every URL and every run of text among the attachments (and the item's own text), then
    /// AteKit's rule for which link is the post.
    @MainActor
    static func read(_ items: [NSExtensionItem]) async -> SharedInput {
        var urls: [URL] = []
        var texts: [String] = []
        for item in items {
            if let words = item.attributedContentText?.string, words.isEmpty == false {
                texts.append(words)
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let words = await Self.loadText(from: provider) {
                    texts.append(words)
                }
            }
        }
        let link = SharedLink.first(urls: urls, texts: texts)
        return SharedInput(link: link, text: SharedLink.text(texts, besides: link))
    }

    /// The provider's URL, or nothing.
    @MainActor
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// The provider's text, or nothing.
    @MainActor
    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}

/// The extension's services: one API client on the shared session, and the three seams the card
/// uses. No Sentry and no TelemetryDeck here — events go to the app through the ``ShareInbox``
/// (``AteTelemetry``).
@MainActor
struct ShareServices {
    let api: AteAPIClient?
    let places: any PlaceDirectory

    static func make() -> ShareServices {
        guard let environment = try? AteEnvironment.resolve(bundle: .main) else {
            return ShareServices(api: nil, places: UnavailablePlaces())
        }
        let api = AteAPIClient(environment: environment)
        return ShareServices(api: api, places: PlaceDirectoryClient(api: api))
    }

    func model() -> ShareCardModel {
        guard let api else {
            return ShareCardModel(
                reader: UnavailableReader(), saves: UnavailableSaves(), places: places, isSignedIn: false,
                analytics: AteTelemetry.record
            )
        }
        return ShareCardModel(
            reader: ReadShareClient(api: api),
            saves: OwnSaveClient(api: api),
            places: places,
            isSignedIn: api.isSignedIn,
            analytics: AteTelemetry.record,
            onSaved: { ShareInbox().markOwnSavesChanged() }
        )
    }
}

// A build whose configuration did not resolve (no Secrets.xcconfig) has no backend: the card says
// "Open Ate to sign in" and these are never reached.

private struct UnavailableReader: ReadSharing {
    func read(url: URL, text: String?) async throws -> ReadShareResult { throw ReadShareError.notAuthenticated }
}

private struct UnavailableSaves: OwnSaving {
    func ownSaves() async throws -> [OwnSave] { throw ReadShareError.notAuthenticated }
    func add(_ draft: OwnSaveDraft) async throws -> UUID { throw ReadShareError.notAuthenticated }
    func remove(id: UUID) async throws { throw ReadShareError.notAuthenticated }
}

private struct UnavailablePlaces: PlaceDirectory {
    func search(_ query: String) async throws -> [PlaceSuggestion] { [] }
    func recents(limit: Int) async throws -> [PlaceSuggestion] { [] }
    func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] { [] }
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef { throw ReadShareError.notAuthenticated }
    func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef {
        throw ReadShareError.notAuthenticated
    }
    func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] { [] }
}

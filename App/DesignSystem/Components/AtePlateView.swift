import AteKit
import SwiftUI
import UIKit
import WebKit

/// What the live plate shows: which award, and what is written on its back.
struct AtePlateSpec: Equatable, Encodable, Sendable {
    let id: String
    let name: String
    let dish: String
    let date: String
    let handle: String
    var dark = true
    /// Rise in with the approved entrance; false shows it at rest.
    var intro = true

    init(award: PlateAward, dish: String?, date: Date, handle: String?, dark: Bool = true, intro: Bool = true) {
        self.id = award.rawValue
        self.name = award.name
        self.dish = dish ?? ""
        self.date = AtePlateSpec.backstampDate(date)
        self.handle = handle ?? ""
        self.dark = dark
        self.intro = intro
    }

    /// "Sat 18 Oct 2026", as the backstamp prints it.
    static func backstampDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            .replacingOccurrences(of: ",", with: "")
    }
}

/// **The live plate's driver** — one per screen that shows a live plate (the takeover, an opened
/// award). The plate itself is the approved three.js engine (`design/plates/`), loaded once into a
/// transparent web view; this sends it what to show and asks it to turn over or play again.
@MainActor
@Observable
final class AtePlateStage {
    private(set) var isReady = false
    @ObservationIgnored fileprivate weak var web: WKWebView?
    @ObservationIgnored private var pending: AtePlateSpec?
    /// Every plate is a `still` away: the share card asks for a big one.
    @ObservationIgnored private var shown: AtePlateSpec?

    func show(_ spec: AtePlateSpec) {
        shown = spec
        guard isReady, let web else {
            pending = spec
            return
        }
        guard let data = try? JSONEncoder().encode(spec), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.ate.show(\(json))", completionHandler: nil)
    }

    func flip() {
        web?.evaluateJavaScript("window.ate.flip()", completionHandler: nil)
    }

    func replay() {
        web?.evaluateJavaScript("window.ate.replay()", completionHandler: nil)
    }

    /// The front of the plate on screen, `side` pixels square, transparent — or nil before the page
    /// is up.
    func still(side: Int) async -> UIImage? {
        guard isReady, let web, let id = shown?.id else { return nil }
        let script = "window.ate.still('\(id)', \(side), false)"
        let url: String? = await withCheckedContinuation { done in
            web.evaluateJavaScript(script) { result, _ in
                done.resume(returning: result as? String)
            }
        }
        guard let url, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        // the page shows the same plate again: `still` swaps the canvas size and back
        return UIImage(data: data)
    }

    fileprivate func didLoad() {
        guard isReady == false else { return }
        isReady = true
        if let pending {
            self.pending = nil
            show(pending)
        }
    }
}

/// **The live plate** — drag to spin, the approved entrance on arrival, the idle sway after.
/// Square; give it a width.
///
/// Its web view comes from `AtePlatePool`: a page that has already started its web process and read
/// three.js, the fonts and the engine, so an opened award only has to paint its own plate.
struct AtePlateView: UIViewRepresentable {
    let stage: AtePlateStage

    func makeCoordinator() -> Coordinator { Coordinator(stage: stage) }

    func makeUIView(context: Context) -> WKWebView {
        let plate = AtePlatePool.take()
        let web = plate.web
        plate.router.onReady = { [weak stage] in stage?.didLoad() }
        web.addGestureRecognizer(context.coordinator.hold)
        context.coordinator.plate = plate
        stage.web = web
        if plate.router.isReady { stage.didLoad() }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.removeGestureRecognizer(coordinator.hold)
        if let plate = coordinator.plate {
            coordinator.plate = nil
            AtePlatePool.giveBack(plate)
        }
    }

    /// The page `design/plates/build.py` writes.
    static let page = Bundle.main.url(forResource: "plate-world", withExtension: "html")

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let stage: AtePlateStage
        fileprivate var plate: AtePlatePool.Plate?
        /// **A drag on the plate spins it; it never takes the page back.** iOS 26 lets a sideways
        /// drag anywhere on a pushed page start the back swipe, and a spin is a sideways drag
        /// (Eamon, build 269). This pan watches every touch on the plate alongside the web view,
        /// cancels nothing, and holds the navigation controller's back swipes until it fails —
        /// which it never does once a drag on the plate has begun.
        let hold = UIPanGestureRecognizer()

        init(stage: AtePlateStage) {
            self.stage = stage
            super.init()
            hold.cancelsTouchesInView = false
            hold.delaysTouchesBegan = false
            hold.delaysTouchesEnded = false
            hold.delegate = self
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            guard let navigation = navigationController(of: gestureRecognizer.view) else { return false }
            return other === navigation.interactiveContentPopGestureRecognizer
                || other === navigation.interactivePopGestureRecognizer
        }

        private func navigationController(of view: UIView?) -> UINavigationController? {
            var responder: UIResponder? = view
            while let next = responder {
                if let controller = next as? UIViewController, let navigation = controller.navigationController {
                    return navigation
                }
                responder = next.next
            }
            return nil
        }
    }
}

/// **One live-plate page, kept warm.** Opening an award used to start a fresh web view every time:
/// a new web process, 1.8 MB of three.js, fonts and engine to read, a WebGL context to make — about
/// a second of blank square before the entrance could start. The pool loads that page once, ahead
/// of time (when a row or grid of plates appears), and hands it to the next live plate; a plate
/// that leaves the screen gives it back. Two live plates at once (the takeover over an opened
/// award) still work: the second gets a fresh page, as before. Memory pressure drops the spare.
@MainActor
enum AtePlatePool {
    final class Plate {
        let web: WKWebView
        let router: Router

        init(web: WKWebView, router: Router) {
            self.web = web
            self.router = router
        }
    }

    /// Hears the page's "ready" and passes it to whichever screen holds the page now. The content
    /// controller holds its handler strongly; this holds nothing back.
    @MainActor
    final class Router: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false
        var onReady: (() -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.body as? String == "ready" else { return }
            isReady = true
            onReady?()
        }
    }

    private static var spare: Plate?
    private static var isWatchingMemory = false

    /// Starts the page now, if there is none waiting, so the next live plate is already loaded.
    static func warm() {
        guard spare == nil else { return }
        spare = make()
        watchMemory()
    }

    static func take() -> Plate {
        if let plate = spare {
            spare = nil
            return plate
        }
        return make()
    }

    /// A plate left the screen: keep its page for the next one, hidden, unless one is already
    /// waiting or it never loaded.
    static func giveBack(_ plate: Plate) {
        plate.router.onReady = nil
        guard spare == nil, plate.router.isReady else {
            discard(plate)
            return
        }
        // nothing of the last plate shows for a frame when the page is next put up
        plate.web.evaluateJavaScript("document.getElementById('stage').style.opacity=0", completionHandler: nil)
        plate.web.removeFromSuperview()
        spare = plate
    }

    private static func make() -> Plate {
        let router = Router()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(router, name: "plate")
        configuration.suppressesIncrementalRendering = true
        // a square the width of the screen, so the page lays out and sizes its canvas while waiting
        let side = UIScreen.main.bounds.width
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side), configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityElementsHidden = true
        if let url = AtePlateView.page {
            web.loadFileURL(url, allowingReadAccessTo: url)
        }
        return Plate(web: web, router: router)
    }

    private static func discard(_ plate: Plate) {
        plate.web.configuration.userContentController.removeScriptMessageHandler(forName: "plate")
        plate.web.stopLoading()
    }

    private static func watchMemory() {
        guard isWatchingMemory == false else { return }
        isWatchingMemory = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let plate = spare {
                    spare = nil
                    discard(plate)
                }
            }
        }
    }
}

/// **A plate's still** — the rows and grids (`design/plates/bake.js`), or, not earned yet, its
/// silhouette: the same outline in one flat colour, no name.
struct AtePlateStill: View {
    let award: PlateAward
    var isHidden = false

    var body: some View {
        if let image = AtePlateStill.image(award) {
            if isHidden {
                Rectangle()
                    .fill(AteAwardColor.silhouette)
                    .mask { Image(uiImage: image).resizable().scaledToFit() }
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityHidden(true)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
        } else {
            Circle()
                .fill(AteAwardColor.silhouette)
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    @MainActor private static var cache: [PlateAward: UIImage] = [:]

    @MainActor
    static func image(_ award: PlateAward) -> UIImage? {
        if let hit = cache[award] { return hit }
        let image = UIImage(named: award.stillName)
        cache[award] = image
        return image
    }
}

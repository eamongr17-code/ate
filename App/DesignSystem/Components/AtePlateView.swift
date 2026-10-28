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
        isReady = true
        if let pending {
            self.pending = nil
            show(pending)
        }
    }
}

/// **The live plate** — drag to spin, the approved entrance on arrival, the idle sway after.
/// Square; give it a width.
struct AtePlateView: UIViewRepresentable {
    let stage: AtePlateStage

    func makeCoordinator() -> Coordinator { Coordinator(stage: stage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakScriptHandler(context.coordinator), name: "plate")
        configuration.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityElementsHidden = true
        stage.web = web
        if let url = AtePlateView.page {
            web.loadFileURL(url, allowingReadAccessTo: url)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "plate")
        web.stopLoading()
    }

    /// The page `design/plates/build.py` writes.
    static let page = Bundle.main.url(forResource: "plate-world", withExtension: "html")

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let stage: AtePlateStage

        init(stage: AtePlateStage) {
            self.stage = stage
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "ready" { stage.didLoad() }
        }
    }

    /// The content controller holds its handler strongly; this keeps it from holding the screen.
    @MainActor
    private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
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

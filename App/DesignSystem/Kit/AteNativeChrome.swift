import SwiftUI
import UIKit

/// **What Ate puts into iOS 26's own chrome** — and nothing more: the tab items' labels in
/// Bricolage, the icons as Lucide templates the system tints, and the ink the selected tab is drawn
/// in. The bar, its glass, its selection highlight, its minimise and the navigation bars stay the
/// system's (`design/rebuild/pattern-contract.html`, "One rule above all").
@MainActor
enum AteNativeChrome {
    /// The tab item labels, at rest and selected. Set once, before the new shell's bar is built;
    /// the current app hides the system tab bar on every page, so it never sees these.
    static func install() {
        let item = UITabBarItem.appearance()
        item.setTitleTextAttributes([.font: AteFont.uiFont(for: .kitTabLabel)], for: .normal)
        item.setTitleTextAttributes([.font: AteFont.uiFont(for: .kitTabLabelSelected)], for: .selected)
    }

    /// What the selected tab, and every bar control, is drawn in: ink, never a colour (the quiet
    /// native state — Eamon, 3 Oct).
    static let tint = AtePalette.automatic.fg
}

extension AteIcon {
    /// The icon as a template image for a system bar item (a `Tab`'s label): drawn once at the size
    /// a tab glyph sits at, tinted by the bar. Lucide, never an SF Symbol.
    @MainActor
    func barImage(size: CGFloat = AteNativeChromeMetrics.tabGlyph) -> Image {
        let key = "\(rawValue)@\(size)"
        if let cached = AteBarImageCache.images[key] { return Image(uiImage: cached) }
        let renderer = ImageRenderer(content: view(size: size).foregroundStyle(.black))
        renderer.scale = AteNativeChromeMetrics.renderScale
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
        AteBarImageCache.images[key] = image
        return Image(uiImage: image)
    }
}

@MainActor
private enum AteBarImageCache {
    static var images: [String: UIImage] = [:]
}

enum AteNativeChromeMetrics {
    /// The old bar's 24pt line icon (`data-s="24"` in every mockup's tab bar)…
    static let tabGlyph: CGFloat = 24
    /// …and the + (`.plusdisc data-s="28"`).
    static let composeGlyph: CGFloat = 28
    /// Rendered at 3x, the densest screen the app runs on.
    static let renderScale: CGFloat = 3
}

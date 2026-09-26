import SwiftUI
import UIKit

/// The four places the app goes. Compose is not one of them — it is the glass `+` beside the bar,
/// and it presents rather than switches.
enum AteTab: String, CaseIterable, Identifiable, Hashable {
    case journal, feed, search, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: "Journal"
        case .feed: "Feed"
        case .search: "Search"
        case .you: "You"
        }
    }

    var icon: AteIcon {
        switch self {
        case .journal: .journal
        case .feed: .feed
        case .search: .search
        case .you: .you
        }
    }
}

/// What the shell's `TabView` selects: a tab, or the compose slot — which presents the composer and
/// is never actually the selection.
///
/// **The bar is iOS 26's own** (Liquid Glass, minimise on scroll, the system's re-tap, haptics and
/// accessibility), with compose as the separate glass circle beside it. iOS 26 has no API for an
/// *action* in that position; the one system slot that floats a circle there is the search role's,
/// so compose takes it, and the shell's selection binding turns "selected" into "present".
enum AteTabSlot: Hashable {
    case tab(AteTab)
    case compose
}

extension AteTab {
    /// The tab's label as the native bar takes it: the ported line icon over the title.
    @MainActor
    var nativeLabel: some View {
        Label { Text(title) } icon: { icon.templateImage() }
    }
}

/// The native bar's one styling hook: its labels in the design's tab type (`tabLabel`, bold when
/// current), through `UITabBarAppearance` — the documented way to style a system tab bar's titles,
/// and one SwiftUI's `TabView` honours on iOS 26 (the older `UITabBarItem` proxy is ignored by the
/// glass bar). Only the title attributes are set: the glass, its tint and its translucency stay the
/// system's.
@MainActor
enum AteTabBarAppearance {
    private static var isInstalled = false

    static func install() {
        guard isInstalled == false else { return }
        isInstalled = true
        let appearance = UITabBarAppearance()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                       appearance.compactInlineLayoutAppearance] {
            layout.normal.titleTextAttributes = [.font: AteFont.uiFont(for: .tabLabel)]
            layout.selected.titleTextAttributes = [.font: AteFont.uiFont(for: .tabLabelActive)]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

extension AteIcon {
    /// The icon as a template bitmap — the only form a native tab bar item accepts. Drawn from the
    /// same artboard geometry and stroke as ``view(size:lineWidth:)``, so the native bar carries the
    /// design's own line icons rather than SF Symbols.
    @MainActor
    func templateImage(
        size: CGFloat = AteMetrics.tabIcon,
        lineWidth: CGFloat = AteIconShape.strokeWidth
    ) -> Image {
        let key = "\(rawValue)-\(size)-\(lineWidth)"
        if let cached = AteTemplateImages.cache[key] { return Image(uiImage: cached) }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let strokes = AteIconShape(paths: strokes).path(in: rect).cgPath
        let fills = AteIconShape(paths: fills).path(in: rect).cgPath
        let image = UIGraphicsImageRenderer(size: rect.size).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.addPath(fills)
            cg.fillPath()
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(lineWidth * size / AteVector.viewBox)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(strokes)
            cg.strokePath()
        }.withRenderingMode(.alwaysTemplate)
        AteTemplateImages.cache[key] = image
        return Image(uiImage: image)
    }
}

@MainActor
private enum AteTemplateImages {
    static var cache: [String: UIImage] = [:]
}

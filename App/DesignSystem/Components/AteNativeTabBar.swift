import SwiftUI
import UIKit

/// **Which bottom bar the shell draws** — a prototype switch, not a setting.
///
/// `custom` is the ratified floating pill (`AteTabBar`) and the only thing a shipped build can be.
/// The two native variants are iOS 26's own `TabView` bar — Liquid Glass, minimise-on-scroll, the
/// system's re-tap, haptics and accessibility — differing only in where the compose action lives:
///
/// - **A** — four tabs, and `+` as the separate glass circle iOS 26 floats beside the bar.
/// - **B** — four tabs, and compose as the `tabViewBottomAccessory` above them.
///
/// Chosen with `-ate-tabbar A|B` on a Debug launch, until one is picked.
enum AteTabBarStyle: Equatable {
    case custom, nativeA, nativeB

    static let argument = "-ate-tabbar"

    var isNative: Bool { self != .custom }

    static let current: AteTabBarStyle = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else {
            return .custom
        }
        switch arguments[index + 1].uppercased() {
        case "A": return .nativeA
        case "B": return .nativeB
        default: return .custom
        }
        #else
        return .custom
        #endif
    }()
}

/// What the native `TabView` selects: a tab, or — variant A only — the compose slot, which presents
/// rather than selects and is never actually the selection.
enum AteTabSlot: Hashable {
    case tab(AteTab)
    case compose
}

extension AteIcon {
    /// The icon as a template bitmap — the only form a native tab bar item accepts. Drawn from the
    /// same artboard geometry and stroke as ``view(size:lineWidth:)``, so the native bar carries the
    /// design's own line icons rather than SF Symbols.
    @MainActor
    func templateImage(
        size: CGFloat = AteMetrics.nativeTabIcon,
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

extension AteTab {
    /// The tab's label as the native bar takes it: the ported line icon over the title.
    @MainActor
    var nativeLabel: some View {
        Label { Text(title) } icon: { icon.templateImage() }
    }
}

/// **Variant B's accessory** — compose, as the bar's bottom accessory. Full width above the tabs at
/// rest; when the bar minimises it moves inline beside the shrunken tab and drops to the icon.
struct AteComposeAccessory: View {
    let action: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.snug) {
                AteIcon.compose.view(size: 20, lineWidth: 2.2)
                if placement != .inline {
                    Text("New entry").ateTextLine(.control)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.fg)
        .accessibilityLabel("New entry")
    }
}

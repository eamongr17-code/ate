import AteKit
import SwiftUI
import UIKit

extension View {
    /// Paints the app in the appearance Settings chose — System follows the phone.
    ///
    /// Applied to the **window** (`overrideUserInterfaceStyle`) rather than with
    /// `preferredColorScheme`: every role colour in the design system is a dynamic `UIColor` that
    /// resolves against the window's traits, and `preferredColorScheme(nil)` is known not to hand a
    /// pinned window back to the system until the next launch. The palette itself is untouched —
    /// this only picks which of its two halves is showing.
    func ateAppearance(_ appearance: AteAppearance) -> some View {
        modifier(AteAppearanceModifier(appearance: appearance))
    }
}

private struct AteAppearanceModifier: ViewModifier {
    let appearance: AteAppearance

    func body(content: Content) -> some View {
        content
            .onAppear { apply(appearance) }
            .onChange(of: appearance) { _, next in apply(next) }
    }

    @MainActor
    private func apply(_ appearance: AteAppearance) {
        let style: UIUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.overrideUserInterfaceStyle = style
        }
    }
}

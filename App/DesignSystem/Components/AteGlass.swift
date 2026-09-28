import SwiftUI

/// **The chrome's glass** (round 5) — the app's own frosted surface, in place of iOS 26's Liquid
/// Glass: a backdrop blur, a warm tint over it (``AteGlassColor``), a hairline rim, and a very light
/// shadow cast only *outside* the shape, so the shadow never greys the glass it lifts (smoked glass
/// is the one thing it must never be).
///
/// One surface for every piece of chrome — the tab bar and its `+`, the top-corner buttons, a
/// pushed page's back button and control group, the journal's month marker — so they read as one
/// family, and none of them as the system's.
extension View {
    /// Draws the glass behind this view, in `shape`.
    func ateGlass<S: InsettableShape>(in shape: S, shadow: AteGlassShadow = .control) -> some View {
        background { AteGlassSurface(shape: shape, shadow: shadow) }
    }
}

/// Which lift the glass takes: the tab bar's (round 4, Eamon's pick), or the smaller controls'.
enum AteGlassShadow {
    case bar, control, none
}

struct AteGlassSurface<S: InsettableShape>: View {
    let shape: S
    var shadow: AteGlassShadow = .control
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let cast {
                // Spread and all, as `ateBackground` casts it: a negative spread shrinks the shape
                // before it blurs.
                shape
                    .inset(by: -cast.spread)
                    .fill(cast.colour)
                    .blur(radius: cast.blur / 2)
                    .offset(y: cast.offsetY)
                    .mask {
                        // Everything but the glass itself.
                        Rectangle()
                            .padding(-cast.blur * 2)
                            .overlay { shape.fill(.black).blendMode(.destinationOut) }
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
            }
            shape.fill(.ultraThinMaterial)
            shape.fill(AteGlassColor.tint.opacity(AteGlassColor.tintOpacity))
            shape.strokeBorder(AteGlassColor.rim, lineWidth: AteGlassSurfaceMetrics.rim)
        }
        .accessibilityHidden(true)
    }

    private var cast: AteShadow? {
        let dark = colorScheme == .dark
        switch shadow {
        case .bar: return dark ? AteShadow.tabBarDark : AteShadow.tabBarLight
        case .control: return dark ? AteShadow.glassDark : AteShadow.glassLight
        case .none: return nil
        }
    }
}

enum AteGlassSurfaceMetrics {
    /// The rim: two device pixels on a 3× screen, as the system glass drew it.
    static let rim: CGFloat = 2.0 / 3.0
}

/// **A round glass button** — a page's back button, a tab root's corner control: one icon in a
/// 44pt disc of the chrome's glass.
struct AteGlassButton: View {
    let icon: AteIcon
    let label: String
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.view(size: size)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .ateGlass(in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(AteGlassPressStyle())
        .foregroundStyle(AteGlassColor.item)
        .accessibilityLabel(label)
    }
}

/// **A row of controls on one piece of glass** — a pushed page's top-right group (edit, share,
/// "…"; or one bookmark). The controls keep their own 44pt hit squares; the glass carries them.
///
/// The glass exists only around controls: while a page's read has not answered (a dish's bookmark,
/// an entry's controls) there is no glass at all — never an empty capsule squeezed to its padding —
/// and it fades in with its controls once they are known.
struct AteGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { controls in
            ZStack {
                if controls.isEmpty == false {
                    HStack(spacing: AteGlassGroupMetrics.spacing) { controls }
                        .padding(.horizontal, AteGlassGroupMetrics.padding)
                        .frame(height: AteMetrics.hit)
                        .ateGlass(in: Capsule())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("nav.controls")
                        .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: controls.isEmpty)
        }
        .foregroundStyle(AteGlassColor.item)
        .environment(\.atePalette, AteGlassGroupMetrics.palette)
    }
}

enum AteGlassGroupMetrics {
    /// Read off iOS 26's glass group: a lone control sits in a 64-wide pill, three in a 212.
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 30
    /// The controls inside take the glass's ink rather than the page's.
    static var palette: AtePalette {
        var palette = AtePalette.automatic
        palette.fg = AteGlassColor.item
        return palette
    }
}

/// A press on glass: the glass dips a touch, the way a key gives under a finger.
struct AteGlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

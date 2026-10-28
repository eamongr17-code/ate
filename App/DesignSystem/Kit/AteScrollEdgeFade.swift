import SwiftUI

/// **A sideways scroll's edges, faded** — where more is waiting past an edge, the row fades out into
/// it over ``AteScrollEdgeFadeMetrics/width`` instead of being cut off; at the start (or the end) that
/// edge is sharp, since nothing is past it. Put it on the horizontal `ScrollView` itself.
struct AteScrollEdgeFade: ViewModifier {
    private struct Edges: Equatable {
        var leading = false
        var trailing = false
    }

    @State private var edges = Edges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geometry in
                let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                let hidden = geometry.contentSize.width - geometry.containerSize.width - offset
                return Edges(
                    leading: offset > AteScrollEdgeFadeMetrics.slack,
                    trailing: hidden > AteScrollEdgeFadeMetrics.slack
                )
            } action: { _, now in
                withAnimation(.easeOut(duration: AteScrollEdgeFadeMetrics.duration)) { edges = now }
            }
            .mask {
                HStack(spacing: 0) {
                    fade(from: .leading, isOn: edges.leading)
                    Rectangle()
                    fade(from: .trailing, isOn: edges.trailing)
                }
            }
    }

    /// One edge's strip of the mask: solid while nothing is past it, a gradient to clear while
    /// something is — the solid layer fades away over the gradient, so the change is never a jump.
    private func fade(from edge: HorizontalEdge, isOn: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: edge == .leading ? .leading : .trailing,
                endPoint: edge == .leading ? .trailing : .leading
            )
            Rectangle().opacity(isOn ? 0 : 1)
        }
        .frame(width: AteScrollEdgeFadeMetrics.width)
    }
}

enum AteScrollEdgeFadeMetrics {
    /// How far the fade runs in from an edge: about half a diet code.
    static let width: CGFloat = 24
    /// Scroll this far before the start fades: a rubber-band bounce is not "more is past here".
    static let slack: CGFloat = 1
    static let duration: Double = 0.15
}

extension View {
    /// ``AteScrollEdgeFade``: fade a sideways scroll's edges where more is past them.
    func ateScrollEdgeFade() -> some View {
        modifier(AteScrollEdgeFade())
    }
}

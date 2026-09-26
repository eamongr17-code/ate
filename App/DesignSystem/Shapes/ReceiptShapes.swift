import AteKit
import SwiftUI

/// **The paper's silhouette**: a 16pt continuous top, square sides, and edge B along the bottom —
/// the symmetrical scallop `EdgeFinal.dc.html` specifies (Eamon, 2026-09-26), on every torn surface.
///
/// One shape rather than a rectangle plus a decorative strip, because the edge has to be part of the
/// paper — fill a slip with this and its tone, its contact line and its edge all agree. The last
/// ``AteMetrics/tornEdgeHeight`` points of the rect are the wave strip: the paper's bottom is that far
/// above the rect's, and the edge dips 0.6pt below it at every valley and 3.6pt at every crest.
///
/// The period is fitted to the width (``WaveEdge``), so a whole number of scallops fits and both
/// ends match — the arithmetic lives in AteKit, where the board's numbers are asserted.
struct ReceiptPaper: Shape {
    var topRadius: CGFloat = AteMetrics.receiptTop

    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY - AteMetrics.tornEdgeHeight
        let top = Path(
            roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, bottom - rect.minY)),
            cornerRadii: RectangleCornerRadii(topLeading: topRadius, topTrailing: topRadius),
            style: .continuous
        )
        return top.union(Self.wave(width: rect.width, originX: rect.minX, bottom: bottom))
    }

    /// The strip under the paper: from a point inside the paper (so the union has no seam) down to
    /// the scallops. One period is `M0,0.6 C P/4,0.6 P/4,3.6 P/2,3.6 S 3P/4,0.6 P,0.6` — horizontal
    /// tangents at every valley and crest.
    static func wave(width: CGFloat, originX: CGFloat, bottom: CGFloat) -> Path {
        let count = WaveEdge.periodCount(forWidth: Double(width))
        let period = width / CGFloat(count)
        let valley = bottom + CGFloat(WaveEdge.valley)
        let crest = bottom + CGFloat(WaveEdge.crest)
        var path = Path()
        path.move(to: CGPoint(x: originX, y: bottom - 1))
        path.addLine(to: CGPoint(x: originX, y: valley))
        for index in 0..<count {
            let start = originX + CGFloat(index) * period
            path.addCurve(
                to: CGPoint(x: start + period / 2, y: crest),
                control1: CGPoint(x: start + period / 4, y: valley),
                control2: CGPoint(x: start + period / 4, y: crest)
            )
            path.addCurve(
                to: CGPoint(x: start + period, y: valley),
                control1: CGPoint(x: start + period * 3 / 4, y: crest),
                control2: CGPoint(x: start + period * 3 / 4, y: valley)
            )
        }
        path.addLine(to: CGPoint(x: originX + width, y: bottom - 1))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Lays this content on torn paper: `EdgeFinal`'s tone (white to 45% of the paper, easing to the
    /// bottom tone at its edge, the strip solid in that tone), the edge-B silhouette, and one contact
    /// line under the whole of it — `y 1, blur 0`, no other shadow. The content leaves
    /// ``AteMetrics/tornEdgeHeight`` of bottom padding for the strip.
    func ateTornPaper(
        _ tone: AtePaperTone = .slip,
        topRadius: CGFloat = AteMetrics.receiptTop
    ) -> some View {
        background {
            GeometryReader { proxy in
                let height = max(proxy.size.height, 1)
                let paper = max(0, height - AteMetrics.tornEdgeHeight) / height
                ReceiptPaper(topRadius: topRadius)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: tone.top, location: 0),
                            .init(color: tone.top, location: paper * AtePaperTone.holdFraction),
                            .init(color: tone.bottom, location: paper),
                            .init(color: tone.bottom, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .shadow(color: tone.contact, radius: 0, x: 0, y: 1)
            }
        }
    }
}

/// The barcode band. A receipt's one piece of pure signage — it says "this was printed" and carries no
/// data, so the pattern is fixed rather than generated from the entry (a scannable code on a share
/// image would be a promise the app can't keep).
struct AteBarcode: View {
    @Environment(\.atePalette) private var palette

    /// The prototype's repeating pattern, as bar/gap widths in points: a 13pt period.
    private static let pattern: [CGFloat] = [2, 3, 1, 2, 3, 2]

    var body: some View {
        Canvas { context, size in
            var origin: CGFloat = 0
            var index = 0
            while origin < size.width {
                let width = Self.pattern[index % Self.pattern.count]
                if index.isMultiple(of: 2) {
                    let bar = CGRect(x: origin, y: 0, width: min(width, size.width - origin), height: size.height)
                    context.fill(Path(bar), with: .color(palette.fg))
                }
                origin += width
                index += 1
            }
        }
        .frame(height: AteMetrics.barcodeHeight)
        .accessibilityHidden(true)
    }
}

/// One horizontal dashed line, drawn rather than typed so it always spans exactly the width it is
/// given. Both the receipt's band rules and its dot leaders are this view with a different dash.
struct AteDashedLine: View {
    var dash: [CGFloat] = AteMetrics.ruleDash
    var opacity: Double = 0.35
    var lineWidth: CGFloat = AteMetrics.ruleWidth
    /// Round for a leader's dots, butt for a rule's dashes — CSS `dotted` is round and `dashed` is
    /// square, and at 1.5px the difference is the difference between a dotted line and a dashed one.
    var lineCap: CGLineCap = .butt
    /// `.vertical` is the statement slip's column divider — the same rule, stood up.
    var axis: Axis = .horizontal

    @Environment(\.atePalette) private var palette

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if axis == .horizontal {
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            } else {
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            context.stroke(
                path,
                with: .color(palette.rule.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap, dash: dash)
            )
        }
        .frame(
            width: axis == .vertical ? lineWidth : nil,
            height: axis == .horizontal ? lineWidth : nil
        )
        .accessibilityHidden(true)
    }
}

/// A receipt's dashed rule — the line that separates its bands.
struct AteDashedRule: View {
    var body: some View { AteDashedLine() }
}

/// The dot leaders between a line item and its score — the detail that makes a list of dishes read as
/// a bill.
/// `border-bottom:1.5px dotted rgba(36,20,31,.3)` — round dots the width of the line, on a 3pt
/// pitch. A zero-length dash with a round cap *is* a circle, which is the only way to get a dot
/// rather than a 1.5×1.5 square out of a stroke.
struct AteDotLeader: View {
    var body: some View {
        AteDashedLine(dash: AteMetrics.leaderDash, opacity: 0.3, lineCap: .round)
            .frame(minWidth: AteMetrics.loose)
    }
}

/// A plain hairline. Design rule 3's "everything else": no container, just a rule between peers.
///
/// A full point, not a device pixel: the artboards write `border-top:1px`, which is a CSS pixel — one
/// *point* — and a third of that reads as a smudge next to the dashed rules it sits among.
struct AteHairline: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Receipt shapes") {
    VStack(spacing: AteMetrics.section) {
        Color.clear
            .frame(height: 120)
            .ateTornPaper()
        AteDashedRule()
        AteDotLeader()
        AteBarcode()
        AteHairline()
    }
    .padding(AteMetrics.gutter)
    .frame(maxHeight: .infinity)
    .ateGround()
}
#endif

import SwiftUI

/// **The paper's silhouette**: a 16pt rounded top, square sides, and a torn bottom edge.
///
/// One shape rather than a rectangle plus a decorative strip, because the tear has to be part of the
/// paper — clip a receipt with this and its shadow, its background and its edge all agree. That is
/// what stops the tear reading as a sticker glued to the bottom of a card.
struct ReceiptPaper: Shape {
    var topRadius: CGFloat = AteMetrics.receiptTop
    var toothHeight: CGFloat = AteMetrics.tornEdgeHeight
    var toothPeriod: CGFloat = AteMetrics.tornEdgePeriod

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(topRadius, rect.width / 2)
        let tearTop = rect.maxY - toothHeight

        path.move(to: CGPoint(x: rect.minX, y: tearTop))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: tearTop))

        // Teeth, walked right to left so the path closes cleanly at the leading edge.
        var tooth = rect.maxX
        while tooth > rect.minX {
            let next = max(rect.minX, tooth - toothPeriod)
            let mid = (tooth + next) / 2
            path.addLine(to: CGPoint(x: mid, y: rect.maxY))
            path.addLine(to: CGPoint(x: next, y: tearTop))
            tooth = next
        }
        path.closeSubpath()
        return path
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
                with: .color(palette.fg.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, dash: dash)
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
struct AteDotLeader: View {
    var body: some View {
        AteDashedLine(dash: AteMetrics.leaderDash, opacity: 0.3)
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
        ReceiptPaper()
            .fill(AteColor.paper)
            .frame(height: 120)
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

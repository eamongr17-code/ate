import AteKit
import MapKit
import SwiftUI

/// **Where a place is** (`dish-page-place-map.html`, A for both pages, Eamon 28 Oct): Apple's map
/// around the place's point with one pin, and the address under it, on one whole slip. The same card
/// on a place page (the address alone) and on a dish page (the place's name over its address).
///
/// Two doors (a button inside a button's label is never heard): the map opens Maps (``onMap``, the
/// pin's old choice of app); the row under it opens the place on a dish page (``onPlace``), and Maps
/// on the place page itself. A place with no point (hand-added, 0014) has no map: the row alone.
///
/// The map is MapKit's own, drawn still (no pan, no zoom): free, with no quota, at any volume.
struct AtePlaceMapCard: View {
    let link: PlaceMapLink
    /// The place's name over the address — a dish page's card. `nil` on the place page itself.
    var title: String?
    let onMap: () -> Void
    /// The row was tapped on a dish page: open the place. `nil` sends the row to Maps too.
    var onPlace: (() -> Void)?

    /// The card is a slip: its ink is the slip's, whatever ground it lies on.
    private let palette = AtePalette.slip

    /// Whether the card has anything to show: a point, an address, or the name over them.
    static func shows(_ link: PlaceMapLink, title: String?) -> Bool {
        link.coordinate != nil || link.addressLines != nil || title != nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.slipCorner, style: .continuous)
        VStack(spacing: 0) {
            if let point = link.coordinate {
                Button(action: onMap) {
                    map(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AtePlaceMapCardCopy.openInMaps(link.name))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("place.map")
            }
            Button(action: onPlace ?? onMap) { row }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(onPlace == nil ? AtePlaceMapCardCopy.openInMaps(link.name) : "")
                .accessibilityIdentifier(onPlace == nil ? "place.address" : "dish.place.card")
        }
        .clipShape(shape)
        .background { shape.fill(AtePaperTone.slip.fill).ateContactLine(.slip) }
        .ateSlip()
    }

    // MARK: - The map

    private func map(_ centre: CLLocationCoordinate2D) -> some View {
        Map(
            initialPosition: .region(MKCoordinateRegion(
                center: centre,
                latitudinalMeters: AtePlaceMapCardMetrics.span,
                longitudinalMeters: AtePlaceMapCardMetrics.span
            )),
            interactionModes: []
        ) {
            Annotation(link.name, coordinate: centre, anchor: .bottom) {
                AtePlaceMapCardPin()
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // Still: the whole map is the door to Maps, and a page's scroll never catches on it.
        .allowsHitTesting(false)
        // A new place is a new map, never the last one's camera.
        .id("\(centre.latitude),\(centre.longitude)")
        .frame(maxWidth: .infinity)
        .frame(height: AtePlaceMapCardMetrics.mapHeight)
        .overlay(alignment: .topTrailing) {
            AteIcon.arrowUpRight.view(size: AtePlaceMapCardMetrics.glyph)
                .foregroundStyle(palette.fg)
                .frame(width: AtePlaceMapCardMetrics.disc, height: AtePlaceMapCardMetrics.disc)
                .glassEffect(.regular, in: .circle)
                .padding(AteMetrics.snug)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    // MARK: - The address

    private var row: some View {
        HStack(spacing: AteMetrics.regular) {
            VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                if let title {
                    Text(title)
                        .ateText(.kitRankedDish)
                        .foregroundStyle(palette.fg)
                    if let address = link.address {
                        Text(address)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                    }
                } else if let lines = link.addressLines {
                    Text(lines.first)
                        .ateText(.pageHeaderLine)
                        .foregroundStyle(palette.fg)
                    if let rest = lines.rest {
                        Text(rest)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if onPlace != nil {
                AteIcon.chevron.view(size: AtePlaceMapCardMetrics.chevron)
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
            } else if link.coordinate == nil {
                // No map above it: the row is the only way to Maps, so it wears the map's mark.
                AteIcon.place.view(size: AtePlaceMapCardMetrics.chevron)
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.vertical, AteMetrics.regular)
        .frame(maxWidth: .infinity, minHeight: AteMetrics.hit, alignment: .leading)
        .contentShape(.rect)
    }
}

/// The place on the card's map (`map-card-pin.html`): a classic map pin in ink with a white centre,
/// outlined in the slip so it parts from any street, its tip on the point.
private struct AtePlaceMapCardPin: View {
    var body: some View {
        let shape = AtePinShape()
        shape
            .fill(AteColor.ink)
            .overlay { shape.stroke(AteColor.slip, lineWidth: AtePlaceMapCardMetrics.pinOutline) }
            .overlay(alignment: .top) {
                Circle()
                    .fill(AteColor.slip)
                    .frame(width: AtePlaceMapCardMetrics.pinDot, height: AtePlaceMapCardMetrics.pinDot)
                    .padding(.top, (AtePlaceMapCardMetrics.pinWidth - AtePlaceMapCardMetrics.pinDot) / 2)
            }
            .frame(width: AtePlaceMapCardMetrics.pinWidth, height: AtePlaceMapCardMetrics.pinHeight)
            .ateShadow(.mapPin)
            .accessibilityHidden(true)
    }
}

/// A map pin's teardrop: a round head the width of the rect, narrowing to a point at the bottom.
struct AtePinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let centre = CGPoint(x: rect.midX, y: rect.minY + radius)
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        // Where the head meets the tail, 30° below either side.
        let left = CGPoint(x: centre.x - radius * 0.866, y: centre.y + radius * 0.5)
        let right = CGPoint(x: centre.x + radius * 0.866, y: centre.y + radius * 0.5)
        var path = Path()
        path.move(to: tip)
        path.addQuadCurve(to: left, control: CGPoint(x: centre.x - radius * 0.45, y: centre.y + radius * 1.15))
        // Over the top, from lower left to lower right (angles grow clockwise on screen).
        path.addArc(center: centre, radius: radius, startAngle: .degrees(150), endAngle: .degrees(390),
                    clockwise: false)
        path.addLine(to: right)
        path.addQuadCurve(to: tip, control: CGPoint(x: centre.x + radius * 0.45, y: centre.y + radius * 1.15))
        path.closeSubpath()
        return path
    }
}

enum AtePlaceMapCardCopy {
    static func openInMaps(_ name: String) -> String { "Open \(name) in Maps" }
}

enum AtePlaceMapCardMetrics {
    /// `.mcard .map { height: 132px }`.
    static let mapHeight: CGFloat = 132
    /// About a few streets either way: enough to place it, close enough to read the street names.
    static let span: CLLocationDistance = 600
    static let disc: CGFloat = 32
    static let glyph: CGFloat = 16
    static let chevron: CGFloat = 15
    /// The pin: 30 wide, 40 tall, a 10 white centre, a 2 slip outline.
    static let pinWidth: CGFloat = 30
    static let pinHeight: CGFloat = 40
    static let pinDot: CGFloat = 10
    static let pinOutline: CGFloat = 2
}

/// **The map card before its place has arrived** — the same whole slip at the card's own size: the
/// map's room, then the name (on a dish page) and the address as still bars, so nothing moves when
/// the card fills in.
struct AtePlaceMapCardSkeleton: View {
    /// A dish page's card, with the place's name over the address.
    var hasTitle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.slipCorner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(AtePalette.slip.hairline)
                .frame(maxWidth: .infinity)
                .frame(height: AtePlaceMapCardMetrics.mapHeight)
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                if hasTitle {
                    AteSkeletonBar(width: AtePlaceMapCardMetrics.titleBar,
                                   height: AtePlaceMapCardMetrics.titleBarHeight)
                }
                AteSkeletonBar(width: AtePlaceMapCardMetrics.lineBar, height: AtePlaceMapCardMetrics.lineBarHeight)
                AteSkeletonBar(width: AtePlaceMapCardMetrics.restBar, height: AtePlaceMapCardMetrics.lineBarHeight)
            }
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.vertical, AteMetrics.regular)
        }
        .clipShape(shape)
        .background { shape.fill(AtePaperTone.slip.fill).ateContactLine(.slip) }
        .ateSkeletonSweep()
        .accessibilityHidden(true)
    }
}

extension AtePlaceMapCardMetrics {
    static let titleBar: CGFloat = 140
    static let titleBarHeight: CGFloat = 16
    static let lineBar: CGFloat = 170
    static let restBar: CGFloat = 220
    static let lineBarHeight: CGFloat = 12
}

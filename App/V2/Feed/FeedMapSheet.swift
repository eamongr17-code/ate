import AteKit
import SwiftUI
import UIKit

/// **The sheet over the dish map** (`nearby-map-2.html`): **Near me** — every dish within 2 km, best
/// first, paged as you scroll — or the suburb after Search here, or, with a pin tapped, that place:
/// its name, where it is, Open place, and its dishes best first. The title says the place only.
///
/// Drawn in the page, not presented: a presented sheet over a pushed page stayed on screen after Back
/// and raced the pushes it made, the map's lost touches in build 214. It floats on glass like the
/// system's, and drags between three heights: minimised to its title, resting, and tall. A finger
/// anywhere on it drags it live; at the tallest the list scrolls, and pulling down with the list at its
/// top hands over to the sheet, as Apple Maps does (Eamon, 28 Oct: only the grabber moved it, and the
/// rest jumped on release). A list too short to fill those heights caps them: the sheet stops just
/// under its last row (Eamon, 27 Oct).
struct FeedMapSheet: View {
    let store: DishMapStore
    @Binding var detent: FeedMapDetent
    let room: FeedMapRoom
    let onDish: (UUID) -> Void
    let onPlace: (UUID) -> Void

    @Environment(\.atePalette) private var palette
    /// How far the finger has pulled the sheet up (down is negative) since the drag began. State, not
    /// gesture state, so it settles back to 0 in the same animation as the new height.
    @State private var pull: CGFloat = 0
    /// The finger's travel when the sheet took it: the sheet moves from there, so a pull handed over
    /// from the list starts where the list stopped, not with a jump.
    @State private var pullStart: CGFloat?
    /// The list is scrolled to its top, so pulling down moves the sheet instead.
    @State private var listAtTop = true
    /// The grabber and the title, measured: minimised, the sheet is exactly this over the home bar.
    @State private var headHeight = FeedMapSheetMetrics.headEstimate
    /// What the list holds (its rows, or the empty state), measured: the sheet is never taller than
    /// it, so a place with five dishes shows no empty paper under them (Eamon, 26 and 27 Oct).
    @State private var listHeight: CGFloat?

    var body: some View {
        // The list scrolls only once the sheet is as tall as it goes and the rows still don't fit.
        let isTall = detent == .high && overflows
        VStack(alignment: .leading, spacing: 0) {
            head
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    // Minimised, the sheet is the head: it grows and shrinks with it, never jumps.
                    withAnimation(detent == .minimised ? AteMotion.panelSettle : nil) { headHeight = measured }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    list
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, room.bottomInset + AteMetrics.section)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= 0.5
            } action: { _, atTop in
                listAtTop = atTop
            }
            // A new list, not the old one's rows moved: a tapped place's dishes (or Near me's, on
            // letting go) come in at the top and fade in, and the old leave at once. Keyed by dish,
            // the rows in both slid through the new ones and their lines faded through each other
            // (Eamon's recording, 28 Oct).
            .id(store.selected?.id)
            .transition(FeedMapSheetMotion.swap)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Minimised is the title alone: no row peeking under it (build 215). It comes back as
            // soon as the sheet is pulled up.
            .opacity(detent == .minimised && pull <= 0 ? 0 : 1)
            // While the sheet has the finger the list holds still.
            .scrollDisabled(isTall == false || pullStart != nil)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .contentShape(.rect)
        .gesture(FeedMapSheetPan(onChange: pulled, onEnd: released))
        .clipShape(.rect(cornerRadius: FeedMapSheetMetrics.radius))
        .glassEffect(.regular, in: .rect(cornerRadius: FeedMapSheetMetrics.radius))
        .padding(.horizontal, FeedMapSheetMetrics.inset)
        .padding(.bottom, FeedMapSheetMetrics.inset)
        .ateAnimation(AteMotion.panelSettle, value: fit)
        .ateAnimation(AteMotion.fillIn, value: store.selected?.id)
        .accessibilityIdentifier("map.sheet")
    }

    // MARK: - Height

    private var height: CGFloat {
        let resting = height(detent)
        return min(max(resting + pull, height(.minimised)), height(.high))
    }

    private func height(_ detent: FeedMapDetent) -> CGFloat {
        room.height(detent, head: headHeight, content: fit)
    }

    /// The list's height, once it holds what it will show: rows, or Near me's empty or failed state.
    /// While Near me loads (or a tapped place has no rows yet), the height doesn't follow the list, so
    /// the sheet doesn't drop and jump back.
    private var fit: CGFloat? {
        if store.selected != nil { return shown?.isEmpty == false ? listHeight : nil }
        return store.phase == .opening ? nil : listHeight
    }

    /// The rows are taller than the tallest sheet, so it scrolls them.
    private var overflows: Bool {
        guard let fit else { return true }
        return room.fits(head: headHeight, content: fit) == false
    }

    /// The finger moved. Below the tallest, or on the grabber and title, the sheet follows it; on the
    /// tallest sheet's list the list scrolls until it is at its top and the finger heads down, and from
    /// there the sheet follows.
    private func pulled(_ finger: FeedMapSheetPan.Value) {
        let isTall = detent == .high && overflows
        if pullStart == nil {
            guard isTall == false || finger.onList == false || (listAtTop && finger.velocity > 0) else { return }
            pullStart = finger.translation
        }
        pull = -(finger.translation - (pullStart ?? 0))
    }

    /// The finger lifted: the sheet settles at the height nearest where its flick would have carried it.
    private func released(_ finger: FeedMapSheetPan.Value) {
        guard let start = pullStart else { return }
        let travel = finger.translation - start + finger.velocity * FeedMapSheetMetrics.flick
        let landing = height(detent) - travel
        let nearest = FeedMapDetent.allCases.min {
            abs(height($0) - landing) < abs(height($1) - landing)
        }
        withAnimation(AteMotion.panelSettle) {
            detent = nearest ?? detent
            pull = 0
        }
        pullStart = nil
    }

    // MARK: - The top: the grabber and the title (or the tapped place)

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(palette.muted.opacity(FeedMapSheetMetrics.grabberOpacity))
                .frame(width: FeedMapSheetMetrics.grabberWidth, height: FeedMapSheetMetrics.grabberHeight)
                .frame(maxWidth: .infinity)
                .padding(.top, FeedMapSheetMetrics.grabberTop)
                .accessibilityHidden(true)
            Group {
                if let place = store.selected {
                    placeHead(place)
                        .transition(FeedMapSheetMotion.swap)
                } else {
                    Text(store.title.text)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("map.title")
                        .transition(FeedMapSheetMotion.swap)
                }
            }
            .padding(.top, FeedMapSheetMetrics.titleTop)
            .padding(.bottom, FeedMapSheetMetrics.titleGap)
            .padding(.horizontal, AteMetrics.gutter)
        }
    }

    // MARK: - The list

    /// Near me (or Search here), or the tapped place's dishes. Tapping a pin or letting it go swaps
    /// the whole list (see the scroll view's `id`): the old goes at once and the new fades in, so the
    /// two never show through each other (build 217) and no row slides across the others (28 Oct).
    @ViewBuilder
    private var list: some View {
        if let shown {
            rows(shown)
        } else {
            nearbyState
        }
    }

    /// The rows on show, or `nil` while Near me has none to show (loading, failed or empty).
    private var shown: [FeedMapSheetRow]? {
        if let place = store.selected { return placeRows(place) }
        guard store.phase == .ready, store.dishes.isEmpty == false else { return nil }
        return nearbyRows
    }

    private func rows(_ rows: [FeedMapSheetRow]) -> some View {
        let letters = DishLetter.neighbourly(rows.map { ($0.id, $0.name) })
        return ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            AteDishRow(
                photo: .dish(letters[index], cover: row.cover),
                name: row.name,
                tags: row.tags,
                subtitle: row.subtitle,
                score: row.score.map(AteScore.average),
                isFirst: index == 0,
                onOpen: { onDish(row.id) }
            )
            .onAppear {
                if store.selected == nil, index == rows.count - 1 { Task { await store.loadMoreDishes() } }
            }
            .transition(FeedMapSheetMotion.swap)
        }
    }

    /// The place's menu, or until it is read, its dishes already in the list (no empty sheet).
    private func placeRows(_ place: MapPlace) -> [FeedMapSheetRow] {
        guard store.selectedMenu.isEmpty else {
            return store.selectedMenu.map { dish in
                FeedMapSheetRow(
                    id: dish.dishID, name: dish.name, cover: dish.coverURLString, tags: dish.tags,
                    subtitle: FeedMapCopy.people(dish.peopleCount), score: dish.score
                )
            }
        }
        // The line the menu's own rows will carry, so nothing changes under them when it lands.
        return store.dishes.filter { $0.restaurantID == place.restaurantID }.map { dish in
            FeedMapSheetRow(
                id: dish.dishID, name: dish.name, cover: dish.coverURLString, tags: [],
                subtitle: FeedMapCopy.people(dish.reviewCount), score: dish.score
            )
        }
    }

    private var nearbyRows: [FeedMapSheetRow] {
        store.dishes.map { dish in
            FeedMapSheetRow(
                id: dish.dishID, name: dish.name, cover: dish.coverURLString, tags: [],
                subtitle: FeedMapCopy.whereAndHowFar(dish.placeName, meters: dish.distanceMeters),
                score: dish.score
            )
        }
    }

    @ViewBuilder
    private var nearbyState: some View {
        switch store.phase {
        case .opening:
            // The kit's dish row skeleton, as Saved and a place's menu load (27 Oct: it redacted a real
            // row with a blank name: a blurred grey tile and a dot, not the row's shape).
            ForEach(0..<FeedMapSheetMetrics.skeletonRows, id: \.self) { _ in
                AteSkeleton(kind: .dishRow)
            }
        case .failed:
            AteEmptyState(line: FeedMapCopy.unreachable, art: .unplugged, pill: (FeedMapCopy.tryAgain, retry))
                .accessibilityIdentifier("map.unreachable")
        case .offline:
            AteEmptyState(line: FeedMapCopy.noConnection, art: .unplugged, pill: (FeedMapCopy.tryAgain, retry))
                .accessibilityIdentifier("map.offline")
        case .ready:
            AteEmptyState(line: store.title.emptyLine, art: .setting, size: .section)
                .accessibilityIdentifier("map.empty")
        }
    }

    // MARK: - A tapped place

    private func placeHead(_ place: MapPlace) -> some View {
        VStack(alignment: .leading, spacing: FeedMapSheetMetrics.headGap) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: FeedMapSheetMetrics.lineGap) {
                    Text(place.name)
                        .ateText(.sheetTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let line = placeLine(place) {
                        Text(line)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                    }
                }
                Spacer(minLength: AteMetrics.gutter)
                AteGlassDisc(icon: .close, label: FeedMapCopy.close, size: FeedMapSheetMetrics.close) {
                    Task { await store.select(nil) }
                }
            }
            AteInkPill(title: FeedMapCopy.openPlace, size: .row, identifier: "map.openPlace") {
                onPlace(place.restaurantID)
            }
            .fixedSize()
        }
    }

    private func placeLine(_ place: MapPlace) -> String? {
        let parts = [place.locality, place.distanceMeters.map(MapDistance.text(meters:))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func retry() {
        Task { await store.retry() }
    }
}

/// One dish in the sheet's list, from Near me or from a tapped place's menu.
struct FeedMapSheetRow: Identifiable {
    let id: UUID
    let name: String
    let cover: String?
    let tags: [DietTag]
    let subtitle: String
    let score: Double?
}

/// **A finger anywhere on the sheet.** A UIKit pan, alongside the list's own: SwiftUI's drag on the
/// list's scroll view only reported once the finger lifted (build 259: the sheet sat still, then
/// jumped), and only the grabber and title followed the finger. The sheet decides, move by move,
/// whether the finger is its or the list's.
struct FeedMapSheetPan: UIGestureRecognizerRepresentable {
    struct Value {
        /// Down from where the finger came down (up is negative).
        var translation: CGFloat
        /// Points a second, down positive.
        var velocity: CGFloat
        /// The finger came down on the list, not the grabber and title.
        var onList: Bool
    }

    let onChange: (Value) -> Void
    let onEnd: (Value) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onList = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, (current is UIScrollView) == false { view = current.superview }
            onList = view != nil
            return true
        }

        /// The list keeps scrolling while the sheet watches; the sheet stops it when it takes over.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }

        /// Up and down only: a sideways swipe is left alone.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) >= abs(velocity.x)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let value = Value(
            translation: recognizer.translation(in: nil).y,
            velocity: recognizer.velocity(in: nil).y,
            onList: context.coordinator.onList
        )
        switch recognizer.state {
        case .began, .changed: onChange(value)
        case .ended, .cancelled, .failed: onEnd(value)
        default: break
        }
    }
}

enum FeedMapSheetMotion {
    /// What changes when a pin is tapped or let go fades in, and what goes leaves at once, so the
    /// old and the new never show through each other.
    static var swap: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }
}

/// The sheet's three heights.
enum FeedMapDetent: CaseIterable {
    /// Down to its title: the map nearly full screen.
    case minimised
    /// Resting: the title and two and a half rows.
    case low
    /// Up under the map's top buttons.
    case high
}

/// The screen the sheet lies in: how tall it is, and what the system keeps at the top and bottom.
/// Everything is measured from the screen's own edges (the page draws under the bars).
struct FeedMapRoom {
    /// The whole screen's height, top bar and home indicator included.
    let screen: CGFloat
    /// The status bar and the top bar (Back, Show my location).
    let topInset: CGFloat
    /// The home indicator.
    let bottomInset: CGFloat
    /// Down from the screen's top to the middle of the top bar's row.
    let barMiddle: CGFloat

    /// The screen and the home indicator come from the window (``AteScreen``): inside a navigation
    /// stack a `GeometryReader`'s bottom inset is not the screen's, and build 215's sheet floated
    /// above it. The top bar's height only the page knows.
    @MainActor
    init(page: GeometryProxy) {
        let statusBar = AteScreen.safeArea.top
        screen = AteScreen.height
        bottomInset = AteScreen.safeArea.bottom
        topInset = max(page.safeAreaInsets.top, statusBar + AteMetrics.hit)
        barMiddle = (statusBar + topInset) / 2
    }

    /// From the sheet's bottom (``FeedMapSheetMetrics/inset`` above the screen's) to its top. `head` is
    /// the grabber and title's measured height: minimised shows that and nothing under it. `content`
    /// is the list's (its rows, or the empty state): resting and tall never go past it.
    func height(_ detent: FeedMapDetent, head: CGFloat, content: CGFloat? = nil) -> CGFloat {
        switch detent {
        case .minimised: return head + homeBar
        case .low: return min(FeedMapMetrics.lowHeight, whole(head: head, content: content))
        case .high: return min(tallest, whole(head: head, content: content))
        }
    }

    /// Whether the whole list fits in the tallest sheet, so nothing scrolls.
    func fits(head: CGFloat, content: CGFloat) -> Bool {
        whole(head: head, content: content) <= tallest
    }

    /// Up under the map's top buttons.
    private var tallest: CGFloat { screen - topInset - 2 * FeedMapSheetMetrics.inset }

    private var homeBar: CGFloat { max(bottomInset - FeedMapSheetMetrics.inset, 0) }

    /// The head, the whole list, a margin under its last row, and the home bar.
    private func whole(head: CGFloat, content: CGFloat?) -> CGFloat {
        guard let content else { return .infinity }
        return head + content + FeedMapSheetMetrics.listBottom + homeBar
    }
}

enum FeedMapSheetMetrics {
    /// The sheet floats this far in from the screen's sides and bottom, as the system's does.
    static let inset: CGFloat = 8
    static let radius: CGFloat = 38
    static let grabberTop: CGFloat = 6
    static let grabberWidth: CGFloat = 36
    static let grabberHeight: CGFloat = 5
    static let grabberOpacity: Double = 0.45
    /// Grabber to title: clear of the sheet's top (Eamon, build 214: the title sat too close to it).
    static let titleTop: CGFloat = 20
    static let titleGap: CGFloat = 12
    /// The grabber and the title, until measured.
    static let headEstimate: CGFloat = 76
    /// Under the list's last row (or the empty state's line), above the home bar, when the sheet fits it.
    static let listBottom: CGFloat = 22
    /// How far ahead a flick carries the sheet: seconds of the finger's speed as it lifts.
    static let flick: CGFloat = 0.2
    static let headGap: CGFloat = 12
    static let lineGap: CGFloat = 4
    static let close: CGFloat = 34
    static let skeletonRows = 3
}

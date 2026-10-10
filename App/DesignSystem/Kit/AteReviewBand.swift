import SwiftUI

/// **A bundle of reviews at one star** (Eamon, 6 Oct) — what a dish page shows in place of every
/// review: "5 stars", how many people, the first few of their avatars overlapping, and a chevron.
/// A tap opens the bundle in place onto its ``AteReviewRow``s (each still with its own exact score);
/// another closes it. The band is a heading, never a score: it prints no number of its own beyond
/// the count.
struct AteReviewBand<Rows: View>: View {
    let title: String
    let countLine: String
    let faces: [AteReviewFace]
    @Binding var isOpen: Bool
    var isFirst = false
    var identifier = "dish.band"
    @ViewBuilder var rows: Rows

    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : AteMotion.fillIn) { isOpen.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(countLine)")
            .accessibilityValue(isOpen ? "Open" : "Closed")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            if isOpen {
                VStack(spacing: 0) { rows }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
    }

    private var header: some View {
        HStack(spacing: AteDishRowMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(title)
                    .ateText(.rowTitle)
                    .foregroundStyle(palette.fg)
                Text(countLine)
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            avatars
            AteIcon.chevronDown.view(size: AteReviewBandMetrics.chevron)
                .foregroundStyle(palette.muted)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .frame(maxWidth: .infinity, minHeight: AteReviewBandMetrics.height)
        .contentShape(.rect)
    }

    /// The first few faces, each overlapping the last, ringed in the ground so they part.
    private var avatars: some View {
        HStack(spacing: -AteReviewBandMetrics.overlap) {
            ForEach(faces.prefix(AteReviewBandMetrics.faceCount)) { face in
                AteAvatar(userID: face.id, handle: face.handle, size: .byline, url: face.avatarURL)
                    .padding(AteReviewBandMetrics.ring)
                    .background(palette.ground, in: .circle)
            }
        }
        .padding(-AteReviewBandMetrics.ring)
        .accessibilityHidden(true)
    }
}

/// One of a band's overlapping avatars.
struct AteReviewFace: Identifiable {
    let id: UUID
    let handle: String
    var avatarURL: URL?
}

enum AteReviewBandMetrics {
    /// The band row: a touch shorter than a review's 64, so a closed page reads as a list of headings.
    static let height: CGFloat = 56
    static let chevron: CGFloat = 16
    /// Three faces at most, the byline's 28, overlapping by 10 as on the entry's "with" line.
    static let faceCount = 3
    static let overlap: CGFloat = 10
    static let ring: CGFloat = 2
}

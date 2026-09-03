import AteKit
import SwiftUI
import UIKit

/// **Custom surface #3** — the receipt (§5.2, §5.3).
///
/// The end of the loop and the only thing in V1 that leaves the app, so it is an *artifact*, not a
/// confirmation screen: the score is the biggest thing on it, the restaurant is named once, and the
/// actions sit below the artifact in the thumb zone. The share sheet is never auto-presented —
/// finishing a log and being ambushed by a share sheet is how you teach people to stop logging.
struct ReceiptView: View {
    let receipt: ReceiptModel
    let model: LogSessionModel
    let onDone: () -> Void

    @State private var shareImage: UIImage?
    @State private var isRendering = true

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.loose) {
                ReceiptArtifact(receipt: receipt, photoURL: model.localPhotoURL(forReceiptLine:))
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.receipt))

                if model.postedWithoutPhoto {
                    // §5.1: a quiet notice. The review is posted; the photo simply isn't on it.
                    Text("Posted without the photo.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                actions
            }
            .padding(Theme.Spacing.comfortable)
        }
        .background(Theme.Color.background)
        .navigationTitle("Posted")
        .navigationBarTitleDisplayMode(.inline)
        // §5.2: there is nothing to go back to — the sitting is committed.
        .navigationBarBackButtonHidden(true)
        .task { await renderShareImage() }
    }

    // MARK: - Actions (§5.2: below the artifact, in the thumb zone)

    /// **Share and Done, and nothing else.** "View dish" was a third button competing with the one
    /// action the receipt loop is judged on, and it led *away* from the artifact at the exact moment
    /// the artifact is the point (device feedback). The dish is one tap away in the feed anyway.
    private var actions: some View {
        VStack(spacing: Theme.Spacing.regular) {
            ReceiptShareButton(
                image: shareImage,
                // §5.3: a failed render degrades to text. Never an error dialog.
                text: receipt.shareText,
                title: receipt.shareTitle,
                isRendering: isRendering,
                onShared: { activityType in
                    model.recordReceiptShared(activityType: activityType)
                }
            )

            Button("Done", action: onDone)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.accent)
                .padding(.top, Theme.Spacing.tight)
        }
    }

    /// §5.3: rendered on APPEAR, not on the Share tap — the share sheet must open instantly.
    private func renderShareImage() async {
        let scale = Theme.Size.receiptExportScale
        let logicalSize = CGSize(
            width: Theme.Size.receiptExport.width / scale,
            height: Theme.Size.receiptExport.height / scale
        )
        let renderer = ImageRenderer(
            content: ReceiptArtifact(
                receipt: receipt,
                photoURL: model.localPhotoURL(forReceiptLine:),
                isExport: true
            )
            .frame(width: logicalSize.width, height: logicalSize.height)
        )
        renderer.scale = scale
        shareImage = renderer.uiImage
        isRendering = false
    }
}

// MARK: - The artifact

/// The receipt's composition — the same view on screen and in the exported image, so a screenshot
/// and a share can't disagree.
///
/// Its colours are the two deliberately non-adaptive tokens in the theme: an image that leaves the
/// device must not depend on the sender's appearance setting.
struct ReceiptArtifact: View {
    let receipt: ReceiptModel
    var photoURL: (ReceiptModel.Line) -> URL?
    /// The export is a fixed 4:5 canvas; on screen the artifact sizes to its content.
    var isExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            place
            if receipt.isSingleDish {
                singleDish
            } else {
                multiDish
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.loose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.receiptBackground)
    }

    // 3. Restaurant + suburb — once, at the top, never per dish.
    //
    // Rule R (§5) applies to the ON-SCREEN artifact only: `isExport` renders the place as flat text,
    // so the shared image is byte-identical whether or not the app could have navigated. The link
    // also renders as text wherever no restaurant routing is installed, which is the case inside the
    // Log sheet today — the seam is here for the day the sheet can push.
    @ViewBuilder
    private var place: some View {
        if !isExport, let restaurantID = receipt.restaurantID {
            RestaurantNameLink(
                name: receipt.restaurantName,
                suburb: receipt.suburb,
                restaurantID: restaurantID,
                from: .receipt,
                style: .inline,
                font: Theme.Text.detail,
                foreground: Theme.Color.receiptSecondary
            )
        } else {
            Text(receipt.placeLine)
                .font(Theme.Text.detail)
                .foregroundStyle(Theme.Color.receiptSecondary)
                .lineLimit(2)
        }
    }

    // 1 + 2 + 4, single dish: the score is the hero, the photo backs it up.
    @ViewBuilder
    private var singleDish: some View {
        if let line = receipt.lines.first {
            VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
                Text(ScoreFormat.outOfFive(line.score.value))
                    .font(Theme.Text.receiptScore)
                    .foregroundStyle(Theme.Color.receiptForeground)
                StarRow(score: line.score.value, starSize: Theme.Size.star * 1.6)
                Text(line.dishName)
                    .font(Theme.Text.sectionTitle)
                    .foregroundStyle(Theme.Color.receiptForeground)
                    .lineLimit(3)
                if let url = photoURL(line), let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(Theme.Ratio.photo, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.photo))
                }
            }
        }
    }

    // 2, multi-dish: one row per dish with a right-aligned score column, and a small leading
    // thumbnail where there's a photo. No photo → the row closes up.
    private var multiDish: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            ForEach(receipt.lines) { line in
                HStack(spacing: Theme.Spacing.regular) {
                    if let url = photoURL(line),
                       let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Theme.Size.thumbnail, height: Theme.Size.thumbnail)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }
                    Text(line.dishName)
                        .font(Theme.Text.itemTitle)
                        .foregroundStyle(Theme.Color.receiptForeground)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.snug)
                    Text(ScoreFormat.average(line.score.value))
                        .font(Theme.Text.scoreNumeral)
                        .foregroundStyle(Theme.Color.receiptForeground)
                }
            }
        }
    }

    // 5 + 6: byline, then the reserved app-locator band. Bottom-most, and deliberately quiet — it
    // must never compete with the score. Its copy is growth-lead's and its look is brand-designer's;
    // this is the slot they land in.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            HStack(spacing: Theme.Spacing.snug) {
                if let author = receipt.author {
                    AvatarView(url: author.avatarURLString.flatMap(URL.init(string:)), size: Theme.Size.avatarSmall)
                    Text(author.handle)
                }
                Spacer(minLength: Theme.Spacing.snug)
                Text(receipt.date, format: .dateTime.day().month(.abbreviated).year())
            }
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.Color.receiptSecondary)

            Text("ate")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.receiptSecondary)
        }
    }
}

// MARK: - Share

/// The native share sheet, presented directly rather than through `ShareLink`.
///
/// `ShareLink` is the stock component and would be the default choice — but it reports nothing back,
/// and `receipt_shared(activity_type)` is the metric the whole receipt loop is judged on (§8). This
/// is the same `UIActivityViewController` `ShareLink` presents, with no custom chrome (§12) — only a
/// completion handler attached.
struct ReceiptShareButton: View {
    let image: UIImage?
    let text: String
    let title: String
    let isRendering: Bool
    let onShared: (String) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: Theme.Spacing.snug) {
                if isRendering { ProgressView().controlSize(.small) }
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .sheet(isPresented: $isPresented) {
            ActivitySheet(items: items, onCompleted: onShared)
        }
    }

    /// §5.3: the image alone by default — a caption nobody wrote is noise. Text only when the render
    /// failed.
    private var items: [Any] {
        if let image { return [image] }
        return [text]
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let onCompleted: (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            guard completed else { return }
            onCompleted(activityType?.rawValue ?? "unknown")
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview("Receipt artifact") {
    ReceiptArtifact(
        receipt: ReceiptModel(
            restaurantName: "Chin Chin",
            suburb: "Melbourne",
            lines: [
                .init(id: UUID(), dishID: UUID(), dishName: "Prawn betel leaf", score: Rating(rounding: 4.5))
            ],
            author: .init(name: "Eamon", handle: "@eamon")
        ),
        photoURL: { _ in nil }
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.receipt))
    .padding(Theme.Spacing.comfortable)
}

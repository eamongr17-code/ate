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
    /// §6's motion moment #2, and the only arrival animation in the app. Latched so it runs ONCE:
    /// a scroll that re-created the view and replayed it would turn a moment into a tic.
    @State private var hasArrived = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.loose) {
                ReceiptArtifact(receipt: receipt, photoURL: model.localPhotoURL(forReceiptLine:))
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.receipt))
                    // The artifact *arrives*: it is the one screen in V1 that is a reward rather
                    // than a destination. Reduce Motion keeps the fade and drops the scale — the
                    // moment survives, the movement doesn't.
                    .scaleEffect(hasArrived || reduceMotion ? 1 : 0.96)
                    .opacity(hasArrived ? 1 : 0)
                    .onAppear {
                        guard !hasArrived else { return }
                        withAnimation(
                            reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)
                        ) {
                            hasArrived = true
                        }
                    }

                if model.postedWithoutPhoto {
                    // §5.1: a quiet notice. The review is posted; the photo simply isn't on it.
                    Text("Posted without the photo.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                actions
            }
            .padding(Theme.Spacing.gutter)
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

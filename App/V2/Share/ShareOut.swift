import MessageUI
import Photos
import SwiftUI
import UIKit

/// **Messages, from the share row** — the system's own compose sheet with the link in the text and
/// the page attached, so the thread shows the picture and the tap opens the entry. Counted only when
/// it was actually sent.
struct MessagesComposer: UIViewControllerRepresentable {
    struct Draft: Identifiable {
        let id = UUID()
        let body: String
        let image: UIImage?
    }

    let draft: Draft
    let onFinish: (Bool) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = draft.body
        if MFMessageComposeViewController.canSendAttachments(), let png = draft.image?.pngData() {
            controller.addAttachmentData(png, typeIdentifier: "public.png", filename: "Ate.png")
        }
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
        ) {
            onFinish(result == .sent)
        }
    }
}

/// **Save image** — the page into Photos, with add-only access (never a read of the library), so
/// a Reel, a TikTok or a carousel can be posted from the camera roll.
enum PhotoSaver {
    @MainActor
    static func save(_ images: [UIImage]) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let pages = images.compactMap { $0.pngData() }
        do {
            try await PHPhotoLibrary.shared().performChanges(creating(pages))
            return true
        } catch {
            return false
        }
    }

    /// The change block, built outside the main actor. Photos runs it on its own queue; a closure
    /// written inside `save` would inherit `@MainActor` and Swift 6 traps the moment it runs there
    /// (the build-111 Save image crash).
    private nonisolated static func creating(_ pages: [Data]) -> @Sendable () -> Void {
        {
            for data in pages {
                guard let image = UIImage(data: data) else { continue }
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}

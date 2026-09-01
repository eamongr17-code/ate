import Foundation
import UIKit

/// Where a picked photo lives between "picked" and "posted" (§7: *"Staged photos in caches dir keyed
/// by draft id"*).
///
/// Caches, not Documents: a staged photo is regenerable (the original is still in the photo library)
/// and losing one to system pressure costs a photo, not a rating. The file name is the card's id —
/// which is also the review id — so a resumed draft finds its photos with no index to keep in sync.
struct StagedPhotoStore: Sendable {
    /// Long edge of the stored JPEG. Big enough for a full-bleed card and the 1080-wide receipt,
    /// small enough that the upload finishes while the person is still rating.
    static let maxDimension: CGFloat = 2_048
    static let compressionQuality: CGFloat = 0.85

    let draftID: UUID
    private let root: URL

    init(draftID: UUID, fileManager: FileManager = .default) {
        self.draftID = draftID
        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        self.root = caches
            .appending(path: "ate-log-drafts")
            .appending(path: draftID.uuidString.lowercased())
    }

    func fileName(for cardID: UUID) -> String {
        "\(cardID.uuidString.lowercased()).jpg"
    }

    func url(for fileName: String) -> URL {
        root.appending(path: fileName)
    }

    /// Downscales, re-encodes as JPEG, writes, and hands back the bytes — the same bytes that go up
    /// to Storage, so what uploads is exactly what the receipt renders.
    @discardableResult
    func stage(_ data: Data, cardID: UUID) -> (fileName: String, data: Data)? {
        guard let image = UIImage(data: data), let jpeg = Self.downscaledJPEG(image) else { return nil }
        let name = fileName(for: cardID)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try jpeg.write(to: url(for: name), options: .atomic)
            return (name, jpeg)
        } catch {
            return nil
        }
    }

    func data(for fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    func remove(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// §7: discarding a draft deletes its staged photos too.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func downscaledJPEG(_ image: UIImage) -> Data? {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension else {
            return image.jpegData(compressionQuality: compressionQuality)
        }
        let scale = maxDimension / longEdge
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
    }
}

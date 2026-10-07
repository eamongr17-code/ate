import AteKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One photo on its way into an entry: the bytes already on disk, and the image to draw.
///
/// The file name is what the draft persists — a container path changes between launches, a name does
/// not — and it is also the upload's source, so a relaunched draft can still post its photos with no
/// photo-library permission and no second trip through the picker.
///
/// **Pending** (round 4): a library pick is in the cluster the instant the picker closes — a still
/// tile, then its preview — while the bytes are written in the background. Until then it has no
/// file, so the draft does not persist it and Done waits for it.
struct StagedPhoto: Identifiable, Equatable {
    let id: String
    /// On the phone, in the draft's photo directory. `nil` for a photo the entry already has, and
    /// for one still being written.
    var fileName: String?
    var image: Image?
    /// A photo the entry being edited already carries — in storage, drawn from its URL.
    var remoteURL: String?
    /// Picked, and still being written to disk.
    var isPending = false
    /// The tile's identity for the whole of its life — pending, previewed, written — so the cluster
    /// never rebuilds it (a rebuilt tile flashes).
    private let tileID = UUID()

    init(id: String, fileName: String, image: Image?) {
        self.id = id
        self.fileName = fileName
        self.image = image
    }

    /// A pick the picker has just handed back: in the cluster now, on disk shortly.
    init(pendingID id: String) {
        self.id = id
        self.fileName = nil
        self.image = nil
        self.isPending = true
    }

    /// One of an edited entry's own photos.
    init(existing photo: EntryCard.Photo) {
        self.id = photo.url
        self.fileName = nil
        self.image = nil
        self.remoteURL = photo.url
    }

    var photo: AtePhoto {
        AtePhoto(
            id: tileID,
            image: image,
            url: remoteURL.flatMap(URL.init(string:))
        )
    }
}

/// **Staging picked photos.** `PhotosPicker` hands back opaque items; this turns each one into a
/// JPEG on disk and a drawable image, in the order they were picked.
///
/// Downscaled and re-encoded on the way in (the design shows them at 90pt, the receipt at 84, and a
/// 12-megapixel original is forty times the bytes of anything the app will ever draw). This is also
/// the only place that touches image data, so the upload never has to think about orientation or
/// format. **Off the main thread** (round 4): ImageIO decodes straight to the size it keeps, so a pick
/// never stalls the words being typed.
@MainActor
enum ComposerPhotoStaging {
    /// The longest edge we keep. Generous for a share card at 3×, meaningless as a download.
    static let maximumDimension: CGFloat = 1600
    static let compressionQuality: CGFloat = 0.8
    /// The preview a pick shows while its bytes are written — about a 116pt tile at 3×.
    static let previewDimension: CGFloat = 360

    /// The picker's key for an item, so the same photo is never staged twice.
    static func key(for item: PhotosPickerItem) -> String {
        item.itemIdentifier ?? UUID().uuidString
    }

    /// One pick, previewed then written. `preview` is called as soon as there is something to draw
    /// (usually well before the file is done); the result is the file name, or `nil` if the photo
    /// could not be read.
    static func stage(
        _ item: PhotosPickerItem,
        in directory: URL,
        preview: @escaping @MainActor (Image) -> Void
    ) async -> (fileName: String, image: Image)? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let fileName = "\(UUID().uuidString.lowercased()).jpg"
        let target = directory.appending(path: fileName)
        let previewSide = previewDimension
        let fullSide = maximumDimension
        let quality = compressionQuality
        let thumbnail = await Task.detached(priority: .userInitiated) {
            ImageProcessing.thumbnail(from: data, maxPixel: previewSide)
        }.value
        if let thumbnail { preview(Image(uiImage: UIImage(cgImage: thumbnail))) }
        let written = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let full = ImageProcessing.thumbnail(from: data, maxPixel: fullSide),
                  ImageProcessing.writeJPEG(full, to: target, quality: quality) else { return nil }
            return full
        }.value
        guard let written else { return nil }
        return (fileName, Image(uiImage: UIImage(cgImage: written)))
    }

    /// Stages images the app already holds — a camera shot, or a cluster picked on `Suggestions`.
    /// Same file, same downscale, same order as the picker's path.
    static func stage(
        images: [(id: String, image: UIImage)],
        in directory: URL,
        existing: [StagedPhoto]
    ) -> [StagedPhoto] {
        var staged = existing
        for candidate in images where staged.count < EntryDraft.photoLimit {
            guard staged.contains(where: { $0.id == candidate.id }) == false,
                  let jpeg = downscaled(candidate.image) else { continue }
            let fileName = "\(UUID().uuidString.lowercased()).jpg"
            guard ImageProcessing.write(jpeg, to: directory.appending(path: fileName)) else { continue }
            staged.append(StagedPhoto(
                id: candidate.id,
                fileName: fileName,
                image: Image(uiImage: UIImage(data: jpeg) ?? candidate.image)
            ))
        }
        return staged
    }

    /// Reloads a relaunched draft's photos straight off disk — no picker, no permission.
    static func restore(fileNames: [String], from directory: URL) -> [StagedPhoto] {
        fileNames.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let image = UIImage(data: data) else { return nil }
            return StagedPhoto(id: name, fileName: name, image: Image(uiImage: image))
        }
    }

    private static func downscaled(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maximumDimension else { return image.jpegData(compressionQuality: compressionQuality) }
        let scale = maximumDimension / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
    }
}

/// The image work, free of the main actor.
enum ImageProcessing {
    /// Decoded straight to at most `maxPixel` on its longest edge, the right way up.
    nonisolated static func thumbnail(from data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A photo is only staged once its bytes are on disk — a photo that is on screen but not on disk
    /// would be a photo Done silently drops.
    nonisolated static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination)
    }

    nonisolated static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

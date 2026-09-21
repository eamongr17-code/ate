import AteKit
import PhotosUI
import SwiftUI

/// One photo on its way into an entry: the bytes already on disk, and the image to draw.
///
/// The file name is what the draft persists — a container path changes between launches, a name does
/// not — and it is also the upload's source, so a relaunched draft can still post its photos with no
/// photo-library permission and no second trip through the picker.
struct StagedPhoto: Identifiable, Equatable {
    let id: String
    let fileName: String
    var image: Image?

    var photo: AtePhoto {
        AtePhoto(id: UUID(uuidString: fileName.replacingOccurrences(of: ".jpg", with: "")) ?? UUID(),
                 image: image)
    }
}

/// **Staging picked photos.** `PhotosPicker` hands back opaque items; this turns each one into a
/// JPEG on disk and a drawable image, in the order they were picked.
///
/// Downscaled and re-encoded on the way in (the design shows them at 90pt, the receipt at 84, and a
/// 12-megapixel original is forty times the bytes of anything the app will ever draw). This is also
/// the only place that touches image data, so the upload never has to think about orientation or
/// format.
@MainActor
enum ComposerPhotoStaging {
    /// The longest edge we keep. Generous for a share card at 3×, meaningless as a download.
    static let maximumDimension: CGFloat = 1600
    static let compressionQuality: CGFloat = 0.8

    static func stage(
        _ items: [PhotosPickerItem],
        in directory: URL,
        existing: [StagedPhoto]
    ) async -> [StagedPhoto] {
        var staged: [StagedPhoto] = []
        for item in items.prefix(EntryDraft.photoLimit) {
            let key = item.itemIdentifier ?? UUID().uuidString
            if let already = existing.first(where: { $0.id == key }) {
                staged.append(already)
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let source = UIImage(data: data),
                  let jpeg = downscaled(source) else { continue }
            let fileName = "\(UUID().uuidString.lowercased()).jpg"
            try? jpeg.write(to: directory.appending(path: fileName), options: .atomic)
            staged.append(StagedPhoto(
                id: key,
                fileName: fileName,
                image: Image(uiImage: UIImage(data: jpeg) ?? source)
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

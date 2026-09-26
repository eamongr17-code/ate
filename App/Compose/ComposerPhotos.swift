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
    /// On the phone, in the draft's photo directory. `nil` for a photo the entry already has.
    let fileName: String?
    var image: Image?
    /// A photo the entry being edited already carries — in storage, drawn from its URL.
    var remoteURL: String?

    init(id: String, fileName: String, image: Image?) {
        self.id = id
        self.fileName = fileName
        self.image = image
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
            id: stableID,
            image: image,
            url: remoteURL.flatMap(URL.init(string:))
        )
    }

    /// The same id every render, so the cluster does not rebuild its tiles.
    private var stableID: UUID {
        if let fileName, let uuid = UUID(uuidString: fileName.replacingOccurrences(of: ".jpg", with: "")) {
            return uuid
        }
        return UUID(uuidString: Self.hashedUUID(id)) ?? UUID()
    }

    private static func hashedUUID(_ string: String) -> String {
        var hasher = Hasher()
        hasher.combine(string)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        let hex = String(format: "%016llx", value)
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.suffix(3))-8000-000000000000"
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

    /// Library picks **append** to what is already staged — a second trip to the picker adds to
    /// the cluster rather than replacing it. A pick already staged is not staged twice; the cap is
    /// the entry's five.
    static func stage(
        _ items: [PhotosPickerItem],
        in directory: URL,
        existing: [StagedPhoto]
    ) async -> [StagedPhoto] {
        var staged = existing
        for item in items where staged.count < EntryDraft.photoLimit {
            let key = item.itemIdentifier ?? UUID().uuidString
            guard staged.contains(where: { $0.id == key }) == false,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let source = UIImage(data: data),
                  let jpeg = downscaled(source) else { continue }
            let fileName = "\(UUID().uuidString.lowercased()).jpg"
            guard write(jpeg, to: directory, as: fileName) else { continue }
            staged.append(StagedPhoto(
                id: key,
                fileName: fileName,
                image: Image(uiImage: UIImage(data: jpeg) ?? source)
            ))
        }
        return staged
    }

    /// A photo is only staged once its bytes are on disk — a photo that is on screen but not on
    /// disk would be a photo Done silently drops.
    private static func write(_ jpeg: Data, to directory: URL, as fileName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: directory.appending(path: fileName), options: .atomic)
            return true
        } catch {
            return false
        }
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
            guard write(jpeg, to: directory, as: fileName) else { continue }
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

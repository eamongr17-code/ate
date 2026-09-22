import AteKit
import Photos
import SwiftUI

/// **The camera roll, as the app needs it**: when photos were taken, a thumbnail, and the bytes.
///
/// A seam rather than a direct `PHAsset` call, because `Suggestions` has to be drivable with no
/// photo-library permission and with fixtures that look like the artboard.
@MainActor
protocol AtePhotoLibrary {
    /// Whether the person has already said yes. Never asks.
    var isAuthorized: Bool { get }
    /// Asks — only ever from `Suggestions`, never at launch.
    func requestAuthorization() async -> Bool
    /// Recent photos, newest first. Empty when there is no permission.
    func recent() async -> [PhotoSuggestionItem]
    func thumbnail(id: String, side: CGFloat) async -> Image?
    /// The bytes the composer stages, at the size it keeps.
    func image(id: String, maximumDimension: CGFloat) async -> UIImage?
}

/// The real one.
@MainActor
final class SystemPhotoLibrary: AtePhotoLibrary {
    var isAuthorized: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: true
        default: false
        }
    }

    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func recent() async -> [PhotoSuggestionItem] {
        guard isAuthorized else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 120
        let result = PHAsset.fetchAssets(with: options)
        var items: [PhotoSuggestionItem] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            items.append(PhotoSuggestionItem(id: asset.localIdentifier, createdAt: created))
        }
        return items
    }

    func thumbnail(id: String, side: CGFloat) async -> Image? {
        let scale = UIScreen.main.scale
        guard let image = await request(id: id, size: CGSize(width: side * scale, height: side * scale),
                                        mode: .aspectFill) else { return nil }
        return Image(uiImage: image)
    }

    func image(id: String, maximumDimension: CGFloat) async -> UIImage? {
        await request(id: id, size: CGSize(width: maximumDimension, height: maximumDimension),
                      mode: .aspectFit)
    }

    private func request(id: String, size: CGSize, mode: PHImageContentMode) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: mode, options: options
            ) { image, info in
                // A degraded first pass is delivered before the real one; only the last reply counts.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard isDegraded == false, hasResumed == false else { return }
                hasResumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

#if DEBUG
/// The design's own three sittings, from the bundled prototype photos — so `Suggestions` can be
/// driven and screenshotted against its artboard with no permission and no camera roll.
@MainActor
final class PreviewPhotoLibrary: AtePhotoLibrary {
    var isAuthorized: Bool { true }
    func requestAuthorization() async -> Bool { true }

    private struct Sitting {
        let offsetDays: Int
        let hour: Int
        let minute: Int
        let names: [String]
    }

    /// `Suggestions.dc.html`: a burger and a cake on Friday night, three dishes last Sunday, sushi
    /// the week before. Dated relative to today so the titles read as they do on the artboard.
    private static let sittings = [
        Sitting(offsetDays: 2, hour: 21, minute: 40, names: ["burger", "cake"]),
        Sitting(offsetDays: 7, hour: 13, minute: 15, names: ["pizza", "penne", "tiramisu"]),
        Sitting(offsetDays: 9, hour: 20, minute: 2, names: ["sushi"])
    ]

    func recent() async -> [PhotoSuggestionItem] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        return Self.sittings.flatMap { sitting -> [PhotoSuggestionItem] in
            let day = calendar.date(byAdding: .day, value: -sitting.offsetDays, to: now) ?? now
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = sitting.hour
            components.minute = sitting.minute
            let start = calendar.date(from: components) ?? day
            return sitting.names.enumerated().map { index, name in
                PhotoSuggestionItem(id: name, createdAt: start.addingTimeInterval(Double(index) * 300))
            }
        }
    }

    func thumbnail(id: String, side: CGFloat) async -> Image? { Image("Photos/\(id)") }

    func image(id: String, maximumDimension: CGFloat) async -> UIImage? {
        UIImage(named: "Photos/\(id)")
    }
}
#endif

import AteKit
import Foundation
import Photos
import UIKit
import Vision

/// **Vision, on the device, asked one question about a photo: what is in it?**
///
/// The labels go to ``FoodPhotoRule`` (AteKit), which decides whether that is a meal. Nothing about
/// the photo leaves the phone — `VNClassifyImageRequest` runs locally, on a small thumbnail that is
/// already on the device (`isNetworkAccessAllowed = false`: an iCloud-only original is not
/// downloaded just to be looked at; it is asked about again on a later visit).
///
/// All the work is on one serial background queue: the image request is synchronous there and
/// Vision's `perform` blocks, so neither goes near the main actor or the cooperative pool.
enum FoodPhotoClassifier {
    /// Vision's classifier works at 299–360px; anything bigger is decoded only to be thrown away.
    private static let side: CGFloat = 360
    private static let queue = DispatchQueue(label: "ate.food-photo-classifier", qos: .utility)

    static func labels(forAssetID id: String) async -> [PhotoLabel]? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: classify(assetID: id))
            }
        }
    }

    private static func classify(assetID: String) -> [PhotoLabel]? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let image = thumbnail(of: asset),
              let cgImage = image.cgImage else { return nil }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(of: image))
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).map { PhotoLabel($0.identifier, $0.confidence) }
    }

    private static func thumbnail(of asset: PHAsset) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var result: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in result = image }
        return result
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// The verdicts, kept between launches so the journal's badge does not send the camera roll back
/// through Vision every time the app opens. A file in Caches: the system may clear it, and then the
/// photos are simply looked at again.
enum FoodPhotoVerdicts {
    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "food-photo-verdicts.json")
    }

    static func load() -> [String: Bool] {
        guard let url, let data = try? Data(contentsOf: url),
              let verdicts = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return verdicts
    }

    static func save(_ verdicts: [String: Bool]) {
        guard let url, let data = try? JSONEncoder().encode(verdicts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

import Foundation
import Supabase

/// Where a review photo lives in Storage.
///
/// The path is fully determined by the viewer and the (client-minted) review id, which is what lets
/// the upload start the moment the photo is picked — before anything has been posted — and still
/// land at the address the review will point at. It also satisfies `review_photos_insert_own`, whose
/// RLS check is `foldername(name)[1] = auth.uid()`: the first segment MUST be the uploader's id.
public enum ReviewPhotoPath {
    public static let bucket = "review-photos"
    public static let fileExtension = "jpg"
    public static let contentType = "image/jpeg"

    public static func path(userID: UUID, reviewID: UUID) -> String {
        "\(userID.uuidString.lowercased())/\(reviewID.uuidString.lowercased()).\(fileExtension)"
    }
}

/// Staging a picked photo and getting a durable URL back. Two methods because the two halves happen
/// at different times: the bytes are written the instant the photo is picked, and the URL is read
/// back once, at the end.
public protocol ReviewPhotoUploading: Sendable {
    /// Uploads the bytes for one card's photo and returns its public URL.
    func upload(_ data: Data, reviewID: UUID) async throws -> URL
}

public struct ReviewPhotoUploadService: ReviewPhotoUploading {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func upload(_ data: Data, reviewID: UUID) async throws -> URL {
        let userID = try await api.requireCurrentUserID()
        let path = ReviewPhotoPath.path(userID: userID, reviewID: reviewID)
        let storage = api.supabase.storage.from(ReviewPhotoPath.bucket)
        // `upsert` so retrying a failed upload (or re-picking a photo for the same card) overwrites
        // rather than 409s — the path is deterministic, so a second attempt is the same object.
        _ = try await storage.upload(
            path,
            data: data,
            options: FileOptions(contentType: ReviewPhotoPath.contentType, upsert: true)
        )
        return try storage.getPublicURL(path: path)
    }
}

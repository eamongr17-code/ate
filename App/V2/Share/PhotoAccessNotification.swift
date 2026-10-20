import AteKit
import SwiftUI

extension Notification.Name {
    /// The Summary's one ask for the camera roll was answered yes: the journal counts its
    /// suggestions again, so "From your photos" can appear.
    static let atePhotoAccessGranted = Notification.Name("ate.photoAccessGranted")
    /// An entry went out holding camera-roll photos: their sittings are no longer on offer.
    static let ateSuggestionPhotosWrittenUp = Notification.Name("ate.suggestionPhotosWrittenUp")
}

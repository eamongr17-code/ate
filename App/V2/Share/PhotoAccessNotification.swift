import AteKit
import SwiftUI

extension Notification.Name {
    /// The Summary's one ask for the camera roll was answered yes: the journal counts its
    /// suggestions again, so "From your photos" can appear.
    static let atePhotoAccessGranted = Notification.Name("ate.photoAccessGranted")
}

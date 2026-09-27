import Foundation

/// **The one quiet ask for the camera roll** (round 5). "From your photos" only appears when there
/// is something to suggest, so someone who was never asked for photos would never find it. They are
/// asked once, at a natural moment: on the Summary, after a post's receipt has printed and settled.
/// The system's prompt carries the whole message (its purpose string); the app adds nothing.
public enum PhotoAccessAsk {
    /// After the receipt enters: the feed, the tear and the photos landing, and a beat to see it.
    public static let delay: Duration = .milliseconds(2200)

    /// Only someone never asked, and only over a receipt that printed: never over a wait, a
    /// failed print, or a launch.
    public static func shouldAsk(canAsk: Bool, isPrinted: Bool) -> Bool {
        canAsk && isPrinted
    }
}

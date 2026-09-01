import AteKit
import CoreLocation
import SwiftUI

/// The device fix the Nearby section needs, and nothing else.
///
/// Spec §6.1: the prompt happens on **first open of the restaurant picker**, never at launch; a
/// denial is silent (Nearby simply doesn't appear, Recents still do) with one dismissible caption
/// row; and if no fix arrives within a few seconds we stop waiting rather than hold the list.
///
/// Built on `CLLocationUpdate.liveUpdates` rather than the `CLLocationManagerDelegate` dance: the
/// async sequence is `Sendable` end to end, so there is no nonisolated-delegate hop to get wrong
/// under strict concurrency.
@MainActor
@Observable
final class SearchLocationProvider {
    /// §6.1: "No fix yet: 3 redacted rows max 3s → Recents."
    static let fixTimeout: Duration = .seconds(3)

    private(set) var origin: SearchOrigin?
    /// True once the user has said no (or the device won't allow it). Drives the caption row —
    /// never a nag, never a second prompt.
    private(set) var isDenied = false
    private(set) var isResolving = false

    private var hasAsked = false

    init(origin: SearchOrigin? = nil) {
        self.origin = origin
    }

    /// Idempotent: safe to call from every `.task`. Returns as soon as there's a fix, a denial, or
    /// the timeout — the caller renders whatever it has either way.
    func requestFix() async {
        guard origin == nil, !isDenied, !isResolving else { return }
        hasAsked = true
        isResolving = true
        defer { isResolving = false }

        let listener = Task { @MainActor [weak self] in await self?.listen() }
        let timeout = Task {
            try? await Task.sleep(for: Self.fixTimeout)
            listener.cancel()
        }
        await listener.value
        timeout.cancel()
    }

    private func listen() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    isDenied = true
                    return
                }
                if let location = update.location {
                    origin = SearchOrigin(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                    return
                }
            }
        } catch {
            // §6.1: no nag, no alert. Nearby is a nicety; Recents and search still work.
        }
    }
}

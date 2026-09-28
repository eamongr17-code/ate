import AteKit
import SwiftUI

/// **What the shell hands a pushed page.** The pages themselves are built in their feature folders,
/// behind ``Route/destination(_:)``; this is the one place the shell's state meets them.
extension AteShell {
    func routeContext(for route: Route) -> RouteContext {
        RouteContext(
            services: services,
            saves: saveAction,
            source: sources[route] ?? .unknown,
            // A receipt is signed. The You header is already loaded by the time a statement can be
            // opened, so its handle is the one on hand; the shell's is the fallback.
            handle: { you.summary?.username ?? handle ?? "" },
            push: { open($0, from: $1) },
            compose: { composing = $0 },
            entryChanged: { card in
                journal.replace(card)
                feed.replace(card)
            },
            blocked: { userID in
                // The person is gone from every read the server serves; the lists on this device
                // catch up now rather than on the next launch.
                if let userID {
                    path.removeAll { $0 == .profile(userID) }
                } else {
                    path.removeAll()
                }
                Task { await feed.refresh() }
            },
            photosChanged: { Task { await countPhotos() } },
            handleChanged: { handleChanged($0) },
            endSession: { endSession(deleting: $0) }
        )
    }
}

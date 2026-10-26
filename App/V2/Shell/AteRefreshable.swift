import SwiftUI

extension View {
    /// **Pull to refresh that SwiftUI can't call off halfway.** `.refreshable` cancels its task when
    /// the page redraws under it — and a refresh redraws the page — so its reads came back as
    /// `URLError.cancelled` and a place page that was showing turned into "Couldn't reach Ate"
    /// (Eamon's build 239 recording). The reads run in their own task, which the gesture awaits, so
    /// the spinner still stays up until they land. Every pull in the app goes through here.
    func ateRefreshable(_ action: @escaping @MainActor () async -> Void) -> some View {
        refreshable {
            await Task { @MainActor in await action() }.value
        }
    }
}

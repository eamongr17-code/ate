import AteKit
import SwiftUI

/// **The Feed tab's stores**, made by its router the first time the tab is shown. Empty until the Feed flow fills it;
/// keep `init(services:)` — ``TabShell`` calls it.
@MainActor
struct V2FeedStores {
    init(services: AteServices) {}
}

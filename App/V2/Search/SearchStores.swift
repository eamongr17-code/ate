import AteKit
import SwiftUI

/// **The Search tab's stores**, made by its router the first time the tab is shown. Empty until the Search flow fills
/// it; keep `init(services:)` — ``TabShell`` calls it.
@MainActor
struct SearchStores {
    init(services: AteServices) {}
}

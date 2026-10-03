import AteKit
import SwiftUI

/// **The Journal tab's stores**, made by its router the first time the tab is shown. Empty until the Journal flow fills
/// it; keep `init(services:)` — ``TabShell`` calls it.
@MainActor
struct JournalStores {
    init(services: AteServices) {}
}

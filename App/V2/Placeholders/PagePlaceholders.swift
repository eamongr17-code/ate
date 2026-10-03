import AteKit
import SwiftUI

/// **A pushed page, as a placeholder**: the native inline bar — the system's back, the page's name
/// centred, the trailing controls as glass items and ••• as a native `Menu` whose Delete carries
/// the system's red role and confirms once — over kit skeletons. The tab bar stays.
struct PagePlaceholder: View {
    let title: String
    var subtitle: String?

    @State private var isSaved = false
    @State private var isConfirmingDelete = false
    @State private var isSharing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AteMetrics.section) {
                AteSkeleton(kind: .hero)
                ForEach(0..<PlaceholderMetrics.rows, id: \.self) { _ in
                    AteSkeleton(kind: .dishRow)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.regular)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityIdentifier("v2.page")
        .ateGround()
        .ateInlineTitle(title, subtitle: subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isSaved.toggle() } label: {
                    (isSaved ? AteIcon.saved : AteIcon.save).view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel(isSaved ? "Saved" : "Save")
                Button { isSharing = true } label: {
                    AteIcon.share.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("Share")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit") {}
                    Button("Delete", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isSharing) {
            AteSheetScaffold(
                title: nil,
                primary: .init(icon: .share, label: "Share") {},
                detents: [.large]
            ) {
                AteSkeleton(kind: .entrySlip, breathes: false)
            }
        }
    }
}

/// **The new app's Settings, as a stub**: the system's inset grouped list on the app's ground, with
/// the one row phase 2b needs — the way back to the current app.
struct SettingsPlaceholder: View {
    let app: AppModel

    var body: some View {
        List {
            Section {
                Button { app.switchToCurrentApp() } label: {
                    Text("Current app")
                        .ateText(.kitListRow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2.settings.currentApp")
            }
            .listRowBackground(AtePalette.automatic.chip)
        }
        .scrollContentBackground(.hidden)
        .ateGround()
        .ateInlineTitle("Settings")
    }
}

/// **The composer, as a placeholder**: the sheet scaffold with close top left and the ink tick top
/// right, muted — the tick waits for a place, and there is no place to attach yet.
struct ComposerSheetPlaceholder: View {
    var body: some View {
        AteSheetScaffold(
            title: nil,
            primary: .init(icon: .check, label: "Done", isEnabled: false) {},
            detents: [.large]
        ) {
            // The words go here; until then the corner row stays at the top of the sheet.
            Color.clear.frame(maxHeight: .infinity)
        }
    }
}

/// **A filter sheet, as a placeholder**: the scaffold's title and its one ink pill at the foot.
struct FilterSheetPlaceholder: View {
    var title = "Filter"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(
            title: title,
            commit: .init(title: "Show 12 entries") { dismiss() }
        ) {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in AteSkeleton(kind: .dishRow, breathes: false) }
            }
        }
    }
}

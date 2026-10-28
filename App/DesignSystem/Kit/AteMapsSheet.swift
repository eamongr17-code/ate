import SwiftUI

/// **Which maps app** — asked from a place's map card when Google Maps is on the phone too: the
/// place's name as the title, Apple Maps and Google Maps as rows, on the one sheet scaffold and in the
/// actions sheet's row anatomy. A row closes the sheet and opens that app.
struct AteMapsSheet: View {
    enum Choice: String, CaseIterable, Identifiable {
        case apple, google
        var id: String { rawValue }
        var title: String { self == .apple ? "Apple Maps" : "Google Maps" }
    }

    let title: String
    let onOpen: (Choice) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(title: title) {
            VStack(spacing: 0) {
                ForEach(Choice.allCases) { app in
                    Button {
                        dismiss()
                        onOpen(app)
                    } label: {
                        VStack(spacing: 0) {
                            AteHairline()
                            HStack(spacing: AteActionsSheetMetrics.gap) {
                                AteIcon.map.view(size: AteActionsSheetMetrics.icon)
                                Text(app.title).ateText(.rowTitle)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: AteActionsSheetMetrics.rowHeight)
                            .contentShape(.rect)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("maps.\(app.rawValue)")
                }
            }
        }
    }
}

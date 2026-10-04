import AteKit
import SwiftUI

/// **`PlaceSheet`** — "Where was this?". The one place a place is chosen, shared by the composer's
/// Place key and the entry's receipt header, so the same action works identically in both.
///
/// Two sections, as `PlaceSheet.dc.html` draws them: **Best match**, which comes from the words
/// somebody typed, and **Nearby**, which comes from the phone — the one screen in the app that asks
/// for location, and only as this sheet opens. Design rule 8 is untouched by that: nearby rooms are
/// *listed*, never attached. A place lands on an entry because it was named or tapped, and a refused
/// permission costs exactly one section.
/// Presented with ``SwiftUICore/View/atePlaceSheet(isPresented:directory:initialQuery:selected:onPick:)``,
/// which reads its first rows before it rises (round 5: it used to open blank, then jump full).
struct PlaceSheet: View {
    let model: PlaceSearchModel
    let directory: any PlaceDirectory
    let onPick: (PlaceRef) -> Void

    @State private var isAddingPlace = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        AteSheet(
            title: "Where was this?",
            searchPrompt: "Search places",
            searchText: $model.query,
            primary: primary,
            isPrimaryBusy: model.isResolving,
            isLoading: model.isReady == false
        ) {
            content(model)
        }
        .ateSurface()
        .task {
            #if DEBUG
            if ComposerDebugLaunch.opensAddPlace { isAddingPlace = true }
            #endif
        }
        .sheet(isPresented: $isAddingPlace) {
            AddPlaceSheet(directory: directory, suggestedName: model.query) { place in
                // Both sheets go in ONE step (round 4, bug c): the place sheet is dismissed with
                // "New place" still on it, which takes the pair down together. Closing "New place"
                // first showed "Where was this?" for a beat before it went too.
                onPick(place)
                dismiss()
            }
        }
    }

    /// "Use …" is there from the tap, and holds still until the row it names is real: a Google
    /// prediction resolves to a restaurant first, and a place with no row is never attached.
    private var primary: (title: String, action: () -> Void)? {
        guard let picked = model.picked else { return nil }
        return ("Use \(picked.name)", {
            guard model.isResolving == false, let resolved = model.picked, resolved.id != nil else { return }
            onPick(resolved)
        })
    }

    @ViewBuilder
    private func content(_ model: PlaceSearchModel) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            if model.hasResultsAnswered == false {
                // Went up before its first rows (past ``SheetReadiness/limit``): still rows, at the
                // sheet's full height, filled in without a move.
                AteSheetSkeletonRows(count: 5)
            } else if model.results.isEmpty == false {
                section(model.sectionTitle) {
                    ForEach(model.results) { suggestion in
                        row(suggestion, model: model)
                    }
                }
            }
            // Absent, not empty, when there is no permission — the design has no "turn on location"
            // copy and this screen is not the place to invent any.
            if model.hasNearbyAnswered == false {
                AteSheetSkeletonRows(count: 3)
            } else if model.nearby.isEmpty == false {
                section("Nearby") {
                    ForEach(model.nearby) { suggestion in
                        row(suggestion, model: model)
                    }
                    addPlaceRow
                }
            } else {
                addPlaceRow
            }
        }
    }

    private func row(_ suggestion: PlaceSuggestion, model: PlaceSearchModel) -> some View {
        AteListRow(
            title: suggestion.name,
            subtitle: suggestion.subtitle,
            leading: { AteIcon.place.view(size: 20) },
            trailing: {
                HStack(spacing: AteMetrics.regular) {
                    if let distance = suggestion.distance {
                        Text(distance)
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.surface.muted)
                    }
                    AteRadioMark(isSelected: model.isSelected(suggestion))
                }
            },
            action: { Task { await model.pick(suggestion) } }
        )
        .accessibilityAddTraits(model.isSelected(suggestion) ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("row.\(suggestion.name)")
    }

    private var addPlaceRow: some View {
        Button {
            isAddingPlace = true
        } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteIcon.compose.view(size: 20)
                    Text("Add a new place").ateText(.control)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 54)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("place.add")
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
                .padding(.top, AteMetrics.tight)
                .padding(.bottom, AteMetrics.snug)
            rows()
        }
    }
}

extension View {
    /// **The place sheet**, the one way it is presented — the composer's Place key, an entry's place
    /// line, the Summary's placeless receipt. A fresh search each time it opens, its first rows (the
    /// recent or best-match places, and those nearby) read before it rises, so it opens full rather
    /// than blank-then-jumping (round 5).
    func atePlaceSheet(
        isPresented: Binding<Bool>,
        directory: any PlaceDirectory,
        initialQuery: @escaping @MainActor () -> String = { "" },
        selected: @escaping @MainActor () -> UUID? = { nil },
        onPick: @escaping (PlaceRef) -> Void
    ) -> some View {
        modifier(PlaceSheetPresenter(
            isPresented: isPresented, directory: directory,
            initialQuery: initialQuery, selected: selected, onPick: onPick
        ))
    }
}

private struct PlaceSheetPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let directory: any PlaceDirectory
    let initialQuery: @MainActor () -> String
    let selected: @MainActor () -> UUID?
    let onPick: (PlaceRef) -> Void

    /// The search the sheet opens on, held by reference: the sheet's content reads it as it changes,
    /// rather than a copy of this modifier captured before the read began.
    @State private var holder = AteSheetHolder<PlaceSearchModel>()

    func body(content: Content) -> some View {
        let holder = holder
        content.ateSheet(isPresented: $isPresented, name: "place", prepare: {
            let fresh = PlaceSearchModel(directory: directory, query: initialQuery(), selected: selected())
            holder.value = fresh
            await fresh.start()
        }, content: {
            AteSheetHolderView(holder: holder) { model in
                PlaceSheet(model: model, directory: directory, onPick: onPick)
            }
        })
    }
}

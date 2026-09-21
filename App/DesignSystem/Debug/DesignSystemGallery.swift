#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Every component, in both modes, on one screen** — plus the composer spike, so the riskiest
/// interaction can be driven with a thumb rather than judged from a diff.
///
/// Debug and Beta only: it reaches TestFlight (where Eamon can open it) and never Release.
struct DesignSystemGallery: View {
    @State private var section: Section = .type
    @State private var scheme: Scheme = .light
    @State private var isComposerPresented = false
    @State private var isTextEditorVariantPresented = false

    private enum Scheme: String, CaseIterable {
        case light, dark
        var colorScheme: ColorScheme { self == .light ? .light : .dark }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case type, colour, receipt, slips, controls, scoring, photos
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            ScrollView {
                VStack(alignment: .leading, spacing: AteMetrics.section) {
                    switch section {
                    case .type: typeSpecimen
                    case .colour: colourSpecimen
                    case .receipt: receiptSpecimen
                    case .slips: slipSpecimen
                    case .controls: controlSpecimen
                    case .scoring: scoringSpecimen
                    case .photos: photoSpecimen
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.vertical, AteMetrics.section)
            }
            .background(AteColor.ground)
        }
        .ateGround()
        .environment(\.colorScheme, scheme.colorScheme)
        .preferredColorScheme(scheme.colorScheme)
        .sheet(isPresented: $isComposerPresented) { ComposerSpike() }
        .sheet(isPresented: $isTextEditorVariantPresented) {
            ScrollView { ComposerTextEditorVariant() }
                .background(AteColor.ground)
                .preferredColorScheme(scheme.colorScheme)
        }
    }

    // MARK: - Chrome

    private var picker: some View {
        VStack(spacing: AteMetrics.snug) {
            HStack {
                Picker("Mode", selection: $scheme) {
                    ForEach(Scheme.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Spacer()
                Button("Composer") { isComposerPresented = true }
                Button("TextEditor") { isTextEditorVariantPresented = true }
            }
            .font(.footnote)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AteMetrics.snug) {
                    ForEach(Section.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Text(item.title)
                                .ateText(.controlSmall)
                                .padding(.horizontal, 12)
                                .frame(height: AteMetrics.chipHeight)
                                .background(
                                    section == item ? AtePalette.automatic.fg : AtePalette.automatic.chip,
                                    in: .capsule
                                )
                                .foregroundStyle(
                                    section == item ? AtePalette.automatic.ground : AtePalette.automatic.fg
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AteMetrics.gutter)
            }
        }
        .padding(.horizontal, AteMetrics.regular)
        .padding(.bottom, AteMetrics.snug)
        .background(.bar)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .ateText(.receiptLabel)
            .foregroundStyle(AtePalette.automatic.muted)
    }

    // MARK: - Specimens

    private var typeSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            label(AteFont.bundledFamiliesAreAvailable ? "Bundled fonts: present" : "Bundled fonts: MISSING (fallback)")
            Text(AteFont.registeredFaceNames.joined(separator: ", "))
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)

            AteWordmark()
            Group {
                Text("Feed").ateText(.screenTitle)
                Text("Tipo 00").ateText(.receiptPlace)
                Text("Which place?").ateText(.sheetTitle)
                Text("Tipo 00").ateText(.slipPlace)
                Text("Butchers Diner").ateText(.feedPlace)
            }
            AteHairline()
            Group {
                Text("Control 15/600").ateText(.control)
                Text("Control small 14/600").ateText(.controlSmall)
                Text("Button 16/700").ateText(.button)
                Text("Meta 13/500").ateText(.meta).foregroundStyle(AtePalette.automatic.muted)
                Text("Journal").ateText(.tabLabelActive)
            }
            AteHairline()
            Text("The tagliatelle al ragù was unreal, rich, glossy, gone in four minutes. "
                + "Tiramisu a bit flat after that.")
                .ateText(.composerProse)
            Text("The same words at 16, which is the size they are on the entry page and in a journal "
                + "slip where they have to share the room with a receipt.")
                .ateText(.prose)
            Text("“Unreal. Rich, glossy, gone in four minutes.”").ateText(.proseNote)
            AteHairline()
            Group {
                Text("01  Tagliatelle al ragù ....... 4.5").ateText(.receiptLine)
                Text("361 Little Bourke St").ateText(.receiptLabel)
            }
        }
    }

    private var colourSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            label("Roles — this surface")
            swatchRow([
                ("ground", AtePalette.automatic.ground), ("fg", AtePalette.automatic.fg),
                ("muted", AtePalette.automatic.muted), ("chip", AtePalette.automatic.chip),
                ("field", AtePalette.automatic.field)
            ])
            label("Roles — on paper")
            swatchRow([
                ("paper", AtePalette.paper.ground), ("ink", AtePalette.paper.fg),
                ("muted", AtePalette.paper.muted), ("chip", AtePalette.paper.chip)
            ])
            label("Accents — ink text in both modes")
            swatchRow([
                ("coral", AteColor.coral), ("butter", AteColor.butter), ("green", AteColor.green),
                ("pink", AteColor.pink), ("sky", AteColor.sky), ("lilac", AteColor.lilac)
            ])
            label("Accent ground")
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                Text("Share").ateText(.screenTitle)
                Text("Ink text on coral, in both modes.").ateText(.prose)
                AteButton(title: "Share", action: {})
            }
            .padding(AteMetrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateAccentGround(AteColor.coral)
            .clipShape(RoundedRectangle(cornerRadius: AteMetrics.receiptTop, style: .continuous))
        }
    }

    private func swatchRow(_ colours: [(String, Color)]) -> some View {
        HStack(spacing: AteMetrics.snug) {
            ForEach(colours, id: \.0) { name, colour in
                VStack(spacing: AteMetrics.tight) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colour)
                        .frame(width: 48, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AtePalette.automatic.hairline)
                        }
                    Text(name).ateText(.meta).foregroundStyle(AtePalette.automatic.muted)
                }
            }
        }
    }

    private var receiptSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            label("Receipt — entry and share show this same component")
            AteReceiptView(receipt: .preview, onPlaceTap: {}, onItemTap: { _ in })
            AteReceiptView(receipt: .previewSingle)
            label("Shapes")
            AteDashedRule()
            AteDotLeader()
            AteBarcode()
            AteHairline()
        }
    }

    private var slipSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            label("Journal slip")
            JournalSlip(slip: .previewJournal, onTap: {})
            JournalSlip(slip: AteSlip(
                place: "Kisume",
                isPublic: false,
                words: .previewFeedWords,
                items: [AteReceipt.Item(name: "Salmon roll", score: Rating(rounding: 4.5)),
                        AteReceipt.Item(name: "Wagyu nigiri")]
            ), onTap: {})
            label("Feed slip")
            FeedSlip(slip: .previewFeed, onTap: {}, onProfileTap: {}, onSaveTap: {})
        }
    }

    private var controlSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            label("Segments, chips, rows, button")
            GalleryControls()
            label("Tab bar")
            AteTabBarSpecimen()
        }
    }

    private var scoringSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            label("Star slider — slide, half steps, haptic ticks, rolling numeral")
            GalleryScoring()
            label("Tokens")
            HStack {
                ScoreToken(rating: Rating(rounding: 4.5))
                ScoreToken(rating: Rating(rounding: 3), isSelected: true)
                PlaceToken(name: "Tipo 00")
            }
            label("Stars — solid outlines, never low opacity")
            HStack(spacing: 0) {
                ForEach(Array([0.0, 0.5, 1.0, 1.0, 0.0].enumerated()), id: \.offset) { _, fill in
                    AteStar(fill: fill)
                }
            }
            label("Inline tokens in read-only prose")
            InlineTokenText(composition: .previewWordsWithPlace, style: .prose)
        }
    }

    private var photoSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            label("Cluster — tilt and overlap, static surfaces only")
            PhotoCluster(photos: AtePhoto.swatches)
            PhotoCluster(photos: AtePhoto.swatches, side: AteMetrics.clusterPhotoComposer)
            label("Straight thumbnail — anything in a scrolling list")
            HStack(spacing: AteMetrics.regular) {
                AteThumbnail(photo: AtePhoto.swatch(AteColor.lilac))
                AteThumbnail(photo: AtePhoto())
            }
            label("Avatars — deterministic from the UUID")
            HStack(spacing: AteMetrics.snug) {
                ForEach(0..<6, id: \.self) { index in
                    AteAvatar(userID: UUID(uuidString: "0000000\(index)-0000-0000-0000-000000000000")!,
                              handle: ["jessw", "marcus", "priya", "tomk", "eamon", "ana"][index])
                }
            }
        }
    }
}

/// Split out so the gallery's own body stays inside SwiftUI's type-checking budget — and so the
/// interactive specimens own their state.
private struct GalleryControls: View {
    @State private var segment = 0
    @State private var picked = 1
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            AteSegments(options: [AteSegment(0, "Journal"), AteSegment(1, "Saved")], selection: $segment)
            HStack {
                AteChip(icon: .place, title: "Melbourne", action: {})
                AteChip(title: "All time")
            }
            AteSearchField(prompt: "Search places", text: $query)
            VStack(spacing: 0) {
                AteListRow(title: "Tipo 00", subtitle: "361 Little Bourke St", action: {})
                AteRadioRow(title: "Kisume", subtitle: "Japanese", isSelected: picked == 1) { picked = 1 }
                AteRadioRow(title: "400 Gradi", subtitle: "Italian", isSelected: picked == 2) { picked = 2 }
            }
            AteButton(icon: .share, title: "Share", action: {})
        }
    }
}

private struct AteTabBarSpecimen: View {
    @State private var tab = AteTab.journal

    var body: some View {
        AteTabBar(selection: $tab, onCompose: {})
            .background(AteColor.ground)
    }
}

private struct GalleryScoring: View {
    @State private var rating: Rating? = Rating(rounding: 4.5)
    @State private var unrated: Rating?

    var body: some View {
        VStack(spacing: AteMetrics.loose) {
            StarSlider(dishName: "Tagliatelle al ragù", rating: $rating)
            StarSlider(dishName: "Prawn spaghetti", rating: $unrated)
        }
    }
}

#Preview("Gallery") { DesignSystemGallery() }
#endif

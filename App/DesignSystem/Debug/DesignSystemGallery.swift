#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Every component, in both modes, on one screen** — plus the composer spike, so the riskiest
/// interaction can be driven with a thumb rather than judged from a diff.
///
/// Debug and Beta only: it reaches TestFlight (where Eamon can open it) and never Release.
struct DesignSystemGallery: View {
    @State private var section: Section
    @State private var scheme: Scheme
    @State private var isComposerPresented: Bool
    @State private var isTextEditorVariantPresented = false
    @State private var variants = AteVariants.shared

    /// Launch arguments open the gallery straight onto a section, a mode, or the composer —
    /// `-ate-gallery-section receipt -ate-gallery-dark`. Screenshotting a component then needs one
    /// launch rather than a sequence of taps that can land on the wrong thing.
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requested = arguments.firstIndex(of: "-ate-gallery-section")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap(Section.init(rawValue:))
        _section = State(initialValue: requested ?? .type)
        _scheme = State(initialValue: arguments.contains("-ate-gallery-dark") ? .dark : .light)
        _isComposerPresented = State(initialValue: arguments.contains("-ate-gallery-composer"))
    }

    private enum Scheme: String, CaseIterable {
        case light, dark
        var colorScheme: ColorScheme { self == .light ? .light : .dark }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case type, voices, colour, receipt, slips, controls, scoring, photos, variants
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
                    case .voices: voiceSpecimen
                    case .colour: colourSpecimen
                    case .receipt: receiptSpecimen
                    case .slips: slipSpecimen
                    case .controls: controlSpecimen
                    case .scoring: scoringSpecimen
                    case .photos: photoSpecimen
                    case .variants: variantSpecimen
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

    /// **The open questions**, each shipped as both answers. A row here is deleted the day its
    /// question is settled — this is not a settings screen in waiting.
    private var variantSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            label("Entry page — which gesture owns a tap on the title and on a bill line")
            Toggle(isOn: Bindable(variants).entryTapOpensDetail) {
                VStack(alignment: .leading, spacing: AteMetrics.tight) {
                    Text("Tap opens the place / dish page")
                        .ateText(.rowTitle)
                    Text(variants.entryTapOpensDetail
                         ? "Long press corrects it. (The default.)"
                         : "Off: the artboard's wiring — a tap corrects, a long press opens the page.")
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                }
            }
            .tint(AtePalette.automatic.fg)
            // The same switch is in the entry page's own context menu, because the gallery is not
            // reachable from a TestFlight build and that page is.
            label("Also on the entry page itself, under a long press")
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

    /// Font metrics for the prose voice, plus the score pill's rendered size — the two things that
    /// decide whether a line with a token in it stays the same height as a line without one.
    private var metrics: String {
        let font = AteFont.uiFont(for: .prose)
        let pill = TokenPill.image(
            for: .score(Rating(rounding: 4.5)), prose: font.pointSize,
            palette: .automatic, dynamicTypeSize: .large, scale: 3
        )
        return String(
            format: "prose %.1fpt  lineHeight %.1f  asc %.1f  desc %.1f  pill %.1f×%.1f",
            font.pointSize, font.lineHeight, font.ascender, font.descender,
            pill?.size.width ?? 0, pill?.size.height ?? 0
        )
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
            // The `wght` axis, driven live. If the variable-font plumbing ever silently falls back,
            // these rows become one weight and the failure is visible instead of theoretical.
            ForEach([200.0, 400.0, 600.0, 800.0], id: \.self) { weight in
                Text(verbatim: "Bricolage \(Int(weight)) — Tagliatelle")
                    .ateText(AteTextStyle(
                        voice: .display, size: 22, weight: weight, trackingEm: -0.02, lineHeight: 1.1,
                        textStyle: .title3
                    ))
            }
            ForEach([300.0, 400.0, 600.0], id: \.self) { weight in
                Text(verbatim: "Newsreader \(Int(weight)) — the words")
                    .ateText(AteTextStyle(voice: .prose, size: 19, weight: weight, lineHeight: 1.3))
            }
            Text(verbatim: "DM Mono 400 / 500 — 01 Tagliatelle 4.5").ateText(.receiptLine)
        }
    }

    /// The named styles, at the sizes `design/v1` sets them.
    private var voiceSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            // Line height is the one metric a screenshot can't be read for, so it is printed.
            Text(verbatim: metrics)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
            Group {
                Text("Feed").ateText(.screenTitle)
                Text("Tipo 00").ateText(.receiptPlace)
                Text("Tipo 00").ateText(.slipPlace)
                Text("Prawn spaghetti").ateText(.slipDish)
                Text("4.5").ateText(.slipScore)
            }
            AteHairline()
            Group {
                Text("Control 15/600").ateText(.control)
                Text("Meta 13/500").ateText(.meta).foregroundStyle(AtePalette.automatic.muted)
                Text("Journal").ateText(.tabLabelActive)
            }
            AteHairline()
            Text("The words at 16, which is the size they are on the entry page and in a journal slip, "
                + "where they share the room with a receipt and have to hold their own rhythm over "
                + "three or four lines.")
                .ateText(.prose)
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
            label("Receipt — what Share prints; the entry page is a page, not a receipt")
            ReceiptView(receipt: .preview, onPlaceTap: {}, onItemTap: { _ in })
            ReceiptView(receipt: .previewSingle)
            label("Shapes")
            AteDashedRule()
            AteDotLeader()
            AteBarcode()
            AteHairline()
        }
    }

    private var slipSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            label("Journal slip — the dish rows, the words, the photos, the foot line")
            EntrySlip(slip: .previewJournal, onOpen: {})
            EntrySlip(slip: AteSlip(
                dishes: [
                    AteSlip.Dish(id: UUID(), dishID: UUID(), name: "Salmon roll",
                                 score: Rating(rounding: 4.5)),
                    AteSlip.Dish(id: UUID(), dishID: UUID(), name: "Wagyu nigiri")
                ],
                place: "Kisume",
                suburb: "CBD",
                meta: .day("Thu 17 Sep"),
                words: .previewFeedWords
            ), onOpen: {})
            label("Feed slip — a byline, and a bookmark on every dish")
            EntrySlip(slip: .previewFeed, onOpen: {}, onProfile: {}, onSave: { _ in },
                      identifier: "feed.slip")
            label("Saved row")
            SavedDishRow(
                dish: SavedDish(
                    dishID: UUID(), dishName: "Prawn spaghetti", restaurantID: UUID(),
                    restaurantName: "Tipo 00", restaurantCity: "CBD", dishScore: 4.4,
                    sourceUsername: "jessw", savedAt: Date()
                ),
                onTap: {}, onUnsave: {}
            )
            label("Statement")
            AteStatsSlip(cells: [("86", "Orders"), ("40", "Places"), ("201", "Dishes")])
        }
    }

    private var controlSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            label("Segments, chips, rows, button")
            GalleryControls()
            label("Tab icons")
            AteTabIconSpecimen()
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
            InlineTokenText(composition: .previewComposerWords, style: .prose)
        }
    }

    /// The gallery is laid out on the screen gutter, not the entry page's margins — the collage is
    /// told the width it has, so it is told this one.
    private var collageWidth: CGFloat { AteScreen.width - 2 * AteMetrics.gutter }

    private var photoSpecimen: some View {
        VStack(alignment: .leading, spacing: AteMetrics.section) {
            label("Cluster — tilt and overlap, static surfaces only")
            PhotoCluster(photos: AtePhoto.swatches)
            PhotoCluster(photos: AtePhoto.swatches, side: AteMetrics.clusterPhotoComposer)
            label("…and the dish hero's own pair: 150pt, lapped 44, −6°/+4°")
            PhotoCluster(
                photos: Array(AtePhoto.swatches.prefix(2)), side: 150,
                overlap: 44, angles: AtePhotoAngles.dishHero
            )
            label("Collage — the entry page, 1 / 2 / 3 photos")
            PhotoCollage(photos: Array(AtePhoto.swatches.prefix(1)), width: collageWidth)
            PhotoCollage(photos: Array(AtePhoto.swatches.prefix(2)), width: collageWidth)
            PhotoCollage(photos: AtePhoto.swatches, width: collageWidth)
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

/// The bar itself is the system's; what the design owns is its icons, as the bar receives them.
private struct AteTabIconSpecimen: View {
    var body: some View {
        HStack(spacing: AteMetrics.section) {
            ForEach(AteTab.allCases) { tab in tab.nativeLabel.labelStyle(.iconOnly) }
            AteIcon.compose.templateImage()
        }
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

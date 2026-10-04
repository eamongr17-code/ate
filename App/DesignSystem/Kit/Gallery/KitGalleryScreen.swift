#if DEBUG || BETA
import AteKit
import SwiftUI

/// **The component kit's gallery** — every atom and composite in every state the contract names
/// (rated and unrated, photo and letter tile, 5.0 and 6, saved and unsaved, loading, empty, long
/// names), on the app's ground in whichever mode the phone is in. Debug and Beta builds only:
/// reached from the foot of Settings, or `-ate-open kit`. This is where the kit is judged before a
/// screen is built from it.
struct KitGalleryScreen: View {
    @State var saved: Set<String> = ["hero", "card.2", "row.3", "ranked.3"]
    @State var chips: [AteFilterChipRow.Chip] = [
        .init(id: "rating", title: "4.0 and up"), .init(id: "diet", title: "GF")
    ]
    @State var isShowingSheet = false
    @State var isShowingActions = false
    @State var query = "Tipo"
    @State var band = ScoreBand(lower: 4, upper: ScoreBand.ceiling)
    @State var window = DateWindow.all
    @State var city = "Melbourne"
    @State var diets: Set<DietTag> = [.gf]
    @State var isShowingPick = false

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: KitGalleryMetrics.sectionGap) {
                    KitBuildStampLine()
                    atoms
                    composites
                    chrome
                }
                .padding(.top, KitGalleryMetrics.top)
                .padding(.bottom, KitGalleryMetrics.bottom)
                // One column the screen's width: a section never widens the page.
                .containerRelativeFrame(.horizontal)
            }
            .onAppear {
                guard let start = Self.startSection else { return }
                Task { @MainActor in reader.scrollTo(start, anchor: .top) }
            }
        }
        .scrollIndicators(.hidden)
        .ateInlineTitle("Component kit")
        .ateGround()
        .sheet(isPresented: $isShowingSheet) { filterSheet(inline: false) }
        .sheet(isPresented: $isShowingActions) { actionsSheet }
        .sheet(isPresented: $isShowingPick) { pickSheet }
        .task { presentFromLaunch() }
        .accessibilityIdentifier("kit.gallery")
    }

    /// `-ate-open kit?section=<name>`: where a drive's screenshot starts.
    private static var startSection: String? {
        #if DEBUG
        DebugLaunch.route?.value(.section)
        #else
        nil
        #endif
    }

    /// `-ate-open kit?present=filter|actions|pick`: that sheet, up at its real detent.
    private func presentFromLaunch() {
        #if DEBUG
        switch DebugLaunch.route?.value(.present) {
        case "filter": isShowingSheet = true
        case "actions": isShowingActions = true
        case "pick": isShowingPick = true
        default: break
        }
        #endif
    }

    // MARK: - Atoms

    @ViewBuilder
    private var atoms: some View {
        section("Score token") {
            row("Row: 4.5 · aggregate 4.3 · perfect 5.0 · secret 6") {
                AteScoreToken(KitFixtures.four)
                AteScoreToken(average: 4.3)
                AteScoreToken(KitFixtures.five)
                AteScoreToken(KitFixtures.six)
            }
            row("Hero") {
                AteScoreToken(KitFixtures.four, size: .hero)
                AteScoreToken(KitFixtures.six, size: .hero)
            }
            row("Inline at 17 and 19") {
                AteScoreToken(KitFixtures.four, size: .inline(prose: 17))
                AteScoreToken(KitFixtures.six, size: .inline(prose: 19))
            }
            row("Unrated: an empty slot") {
                AteScoreToken(nil)
                AteScoreToken(nil, size: .hero)
            }
        }
        section("Diet chip") {
            row("On paper") {
                ForEach(DietTag.allCases, id: \.self) { AteDietChip(tag: $0) }
            }
            .padding(.vertical, KitGalleryMetrics.paperPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ateSlip()
            .background(AtePalette.slip.ground, in: .rect(cornerRadius: AteMetrics.slipCorner))
            .padding(.horizontal, KitGalleryMetrics.cardMargin)
            row("On the ground") {
                ForEach(DietTag.allCases, id: \.self) { AteDietChip(tag: $0, onGround: true) }
            }
        }
        section("Thumb") {
            row("Row 56: photo, letter · Menu 48: photo, letter") {
                AteThumb(photo: KitFixtures.ragu)
                AteThumb(photo: KitFixtures.pho)
                AteThumb(photo: KitFixtures.prawn, size: .menu)
                AteThumb(photo: KitFixtures.souvlaki, size: .menu)
            }
            row("Shelf card: photo, letter") {
                AteThumb(photo: KitFixtures.burger, size: .card)
                AteThumb(photo: KitFixtures.croissant, size: .card)
            }
            caption("Hero: photo, letter")
            VStack(spacing: AteMetrics.regular) {
                AteThumb(photo: KitFixtures.sushi, size: .hero)
                AteThumb(photo: KitFixtures.focaccia, size: .hero)
            }
            .padding(.horizontal, KitGalleryMetrics.cardMargin)
        }
        section("Photo cluster") {
            caption("Slip 80 on paper · one photo has no ring")
            HStack(alignment: .top, spacing: AteMetrics.section) {
                AtePhotoCluster(photos: KitFixtures.photos, surface: AtePaperTone.slip.ring)
                AtePhotoCluster(photos: [KitFixtures.burger], surface: AtePaperTone.slip.ring)
            }
            .padding(KitGalleryMetrics.paperPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AtePalette.slip.ground, in: .rect(cornerRadius: AteMetrics.slipCorner))
            .padding(.horizontal, KitGalleryMetrics.cardMargin)
            caption("Entry 104")
            AtePhotoCluster(photos: KitFixtures.photos, size: .entry)
                .padding(.horizontal, AteMetrics.gutter)
            caption("Summary 96 on coral")
            AtePhotoCluster(photos: KitFixtures.photos, size: .summary, surface: AteColor.coral)
                .padding(AteMetrics.section)
                .frame(maxWidth: .infinity)
                .ateAccentGround(AteColor.coral)
        }
        section("Avatar") {
            row("Byline 28 · review 36 · profile 76") {
                AteAvatar(userID: KitFixtures.jess.userID, handle: "jessw", size: .byline)
                AteAvatar(userID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, handle: "marcus",
                          size: .review)
                AteAvatar(userID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, handle: "priya",
                          size: .profile)
            }
        }
        section("Save") {
            row("Plain: unsaved, saved") {
                AteSaveButton(dishName: "Tiramisu", isSaved: saved.contains("plain.1")) { toggle("plain.1") }
                AteSaveButton(dishName: "Tiramisu", isSaved: saved.contains("plain.2") == false) { toggle("plain.2") }
            }
            row("Glass on a photo: card 36, hero 44") {
                ZStack {
                    AteThumb(photo: KitFixtures.pizza, size: .card)
                    HStack(spacing: AteMetrics.regular) {
                        AteSaveButton(dishName: "Margherita", isSaved: saved.contains("glass.1"),
                                      style: .glass(.card)) { toggle("glass.1") }
                        AteSaveButton(dishName: "Margherita", isSaved: saved.contains("glass.2") == false,
                                      style: .glass(.hero)) { toggle("glass.2") }
                    }
                }
            }
        }
        section("Glass disc and group") {
            row("Close · Share · tick ready · tick, no place · posting") {
                AteGlassDisc(icon: .close, label: "Close") {}
                AteGlassDisc(icon: .share, label: "Share") {}
                AteGlassDisc(icon: .check, label: "Done", role: .primary) {}
                AteGlassDisc(icon: .check, label: "Done", role: .primary, isEnabled: false) {}
                AteGlassDisc(icon: .check, label: "Done", role: .primary, isBusy: true) {}
            }
            row("Group of three with a count") {
                AteGlassGroup {
                    AteGlassItem(icon: .photoStack, label: "Photos", badge: 5) {}
                    AteGlassItem(icon: .calendar, label: "Calendar") {}
                    AteGlassItem(icon: .listFilter, label: "Filter") {}
                }
            }
            row("Over a photo") {
                ZStack {
                    AteThumb(photo: KitFixtures.penne, size: .card)
                    AteGlassDisc(icon: .close, label: "Close") {}
                }
            }
        }
        section("Ink pill") {
            VStack(spacing: AteMetrics.regular) {
                AteInkPill(title: "Show 12 entries") {}
                AteInkPill(title: "Show 0 entries", isEnabled: false) {}
                AteInkPill(title: "Write your first", size: .empty) {}
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
        section("Composer key") {
            row("Score · Score sliding · Place · Place held · Diet") {
                AteKey(kind: .score) {}
                AteKey(kind: .score, isActive: true) {}
                AteKey(kind: .place(nil)) {}
            }
            row("") {
                AteKey(kind: .place(KitFixtures.longPlace)) {}
                AteKey(kind: .diet) {}
            }
            row("Diet, unfolded") {
                ForEach(DietTag.allCases, id: \.self) { tag in AteKey(kind: .code(tag)) {} }
            }
            .environment(\.atePalette, .surface)
            .padding(.vertical, AteMetrics.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AtePalette.surface.ground)
        }
    }
}

/// **Which build this is** — the commit's short SHA left and its date right, written into the bundle
/// as `AteCommit` / `AteCommitDate` in Info.plist from the `ATE_COMMIT` build settings, so a
/// screenshot can be tied to a commit.
struct KitBuildStampLine: View {
    private static func value(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, value.isEmpty == false
        else { return nil }
        return value
    }

    var body: some View {
        HStack {
            Text(verbatim: Self.value("AteCommit") ?? "unstamped build")
            Spacer(minLength: AteMetrics.snug)
            Text(verbatim: Self.value("AteCommitDate") ?? "")
        }
        .ateText(.receiptLabel)
        .foregroundStyle(AtePalette.automatic.muted)
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityIdentifier("kit.stamp")
    }
}

enum KitGalleryMetrics {
    static let top: CGFloat = 14
    static let bottom: CGFloat = 120
    static let sectionGap: CGFloat = 36
    static let itemGap: CGFloat = 12
    static let paperPadding: CGFloat = 16
    static let cardMargin: CGFloat = 16
    /// An inline sheet's frame, standing in for the presented sheet.
    static let sheetHeight: CGFloat = 640
    static let shortSheetHeight: CGFloat = 400
    static let emptyHeight: CGFloat = 300
}
#endif

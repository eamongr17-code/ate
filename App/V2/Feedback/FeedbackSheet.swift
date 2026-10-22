import AteKit
import Photos
import PhotosUI
import SwiftUI

/// Where a tester has been, for the report: one trail for the app.
extension ScreenTrail {
    static let app = ScreenTrail()
}

extension Route {
    /// The page's kind, never its id or its words — what the report's "Last screens" shows.
    var trailName: String {
        String(String(describing: self).prefix { $0 != "(" })
    }
}

/// **Feedback** (`design/rebuild/feedback.html` C–E) — the Journal's bug, for testers. Close top left,
/// the send arrow top right, the title, the words. Under them today's screenshots, newest first: tap
/// one to attach it; the + opens the picker on Screenshots. Three at most. The build and device go
/// with it, in fine print so the tester can see them. Sent, the sheet drops with a success haptic;
/// offline, the report waits in the outbox and sends itself.
struct FeedbackSheet: View {
    let app: AppModel

    @State private var words = ""
    @State private var today: [FeedbackShot] = []
    @State private var picked: [FeedbackShot] = []
    @State private var attached: [String] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var refusal: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.atePalette) private var palette

    private var shots: [FeedbackShot] { picked + today }
    private var canSend: Bool { FeedbackRules.canSend(words) && isSending == false }

    var body: some View {
        AteSheetScaffold(
            title: "Feedback",
            primary: AteSheetPrimary(
                icon: .arrowUp, label: "Send", isEnabled: canSend, isBusy: isSending, action: send
            ),
            detents: [.large]
        ) {
            VStack(alignment: .leading, spacing: FeedbackMetrics.gap) {
                field
                if let refusal {
                    Text(refusal)
                        .ateText(.meta)
                        .foregroundStyle(AteColor.coral)
                }
                Text("Screenshots from today")
                    .ateText(.control)
                    .foregroundStyle(palette.fg)
                    .padding(.top, AteMetrics.tight)
                tiles
                Text(FeedbackDevice.summary)
                    .ateText(.scaleLabel)
                    .foregroundStyle(palette.muted)
            }
        }
        .onAppear {
            isFocused = true
            app.services.analytics(FeedbackEvents.opened())
        }
        .task { await loadToday() }
        .onChange(of: pickerItems) { _, items in
            guard items.isEmpty == false else { return }
            Task { await take(items) }
        }
        .onChange(of: words) { _, now in
            if now.count > FeedbackRules.bodyCap { words = String(now.prefix(FeedbackRules.bodyCap)) }
            refusal = nil
        }
        .interactiveDismissDisabled(isSending)
    }

    private var field: some View {
        TextField(text: $words, axis: .vertical) {
            Text("What happened?").foregroundStyle(palette.muted)
        }
        .lineLimit(FeedbackMetrics.lines, reservesSpace: true)
        .ateText(.rowTitle)
        .textFieldStyle(.plain)
        .foregroundStyle(palette.fg)
        .tint(AteColor.coral)
        .focused($isFocused)
        .textInputAutocapitalization(.sentences)
        .padding(.horizontal, AteMetrics.loose)
        .padding(.vertical, FeedbackMetrics.fieldPadding)
        .background(palette.field, in: .rect(cornerRadius: FeedbackMetrics.fieldCorner))
        .accessibilityLabel("What happened?")
        .accessibilityIdentifier("feedback.words")
    }

    private var tiles: some View {
        ScrollView(.horizontal) {
            HStack(spacing: FeedbackMetrics.tileGap) {
                ForEach(shots) { shot in
                    FeedbackTile(shot: shot, isOn: attached.contains(shot.id)) { toggle(shot) }
                }
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(1, FeedbackRules.screenshotCap - attached.count),
                    matching: .screenshots
                ) {
                    AteIcon.compose.view(size: FeedbackMetrics.plusGlyph)
                        .foregroundStyle(palette.muted)
                        .frame(width: FeedbackMetrics.tileWidth, height: FeedbackMetrics.tileHeight)
                        .overlay {
                            RoundedRectangle(cornerRadius: FeedbackMetrics.tileCorner)
                                .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                }
                .disabled(attached.count >= FeedbackRules.screenshotCap)
                .accessibilityLabel("Add a screenshot")
                .accessibilityIdentifier("feedback.addScreenshot")
            }
            .padding(FeedbackMetrics.ring)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func toggle(_ shot: FeedbackShot) {
        if let index = attached.firstIndex(of: shot.id) {
            attached.remove(at: index)
            AteHaptics.tick()
        } else if attached.count < FeedbackRules.screenshotCap {
            attached.append(shot.id)
            AteHaptics.tick()
        } else {
            AteHaptics.refused()
        }
    }

    // MARK: - Screenshots

    /// Today's screenshots, if Ate already may read the library. Never asks.
    private func loadToday() async {
        guard app.services.isPreviewData == false, app.services.photos.isAuthorized else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0 AND creationDate >= %@",
            PHAssetMediaSubtype.photoScreenshot.rawValue, Calendar.current.startOfDay(for: Date()) as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = FeedbackMetrics.todayLimit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var ids: [String] = []
        assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        var loaded: [FeedbackShot] = []
        for id in ids {
            guard let thumbnail = await app.services.photos.thumbnail(id: id, side: FeedbackMetrics.tileHeight)
            else { continue }
            loaded.append(FeedbackShot(id: id, thumbnail: thumbnail, data: nil))
        }
        today = loaded
    }

    /// From the picker: decoded, downscaled, attached straight away.
    private func take(_ items: [PhotosPickerItem]) async {
        pickerItems = []
        for item in items where attached.count < FeedbackRules.screenshotCap {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = FeedbackImage.jpeg(from: data) else { continue }
            let thumbnail = UIImage(data: jpeg).map { Image(uiImage: $0) } ?? Image(uiImage: UIImage())
            let shot = FeedbackShot(id: "picked-\(UUID().uuidString)", thumbnail: thumbnail, data: jpeg)
            picked.insert(shot, at: 0)
            attached.append(shot.id)
        }
    }

    private func jpegs() async -> [Data] {
        var out: [Data] = []
        for id in attached {
            guard let shot = shots.first(where: { $0.id == id }) else { continue }
            if let data = shot.data {
                out.append(data)
            } else if let image = await app.services.photos.image(id: id, maximumDimension: FeedbackImage.longest),
                      let jpeg = image.jpegData(compressionQuality: FeedbackImage.quality) {
                out.append(jpeg)
            }
        }
        return out
    }

    // MARK: - Send

    private func send() {
        guard canSend else { return }
        isSending = true
        isFocused = false
        Task {
            let report = FeedbackReport(
                body: words, screenshots: await jpegs(), build: FeedbackDevice.build,
                device: FeedbackDevice.model, osVersion: FeedbackDevice.os, screens: ScreenTrail.app.screens
            )
            do {
                let queued = try await app.services.feedback.send(report)
                app.services.analytics(FeedbackEvents.sent(screenshots: report.screenshots.count, queued: queued))
                AteHaptics.success()
                dismiss()
            } catch {
                let reason = FeedbackError.of(error)
                app.services.analytics(FeedbackEvents.refused(reason))
                AteHaptics.refused()
                refusal = Self.words(for: reason)
                isSending = false
            }
        }
    }

    private static func words(for error: FeedbackError) -> String {
        switch error {
        case .rateLimited: "That's ten in an hour. Try again later."
        case .signedOut: "Sign in to send feedback."
        case .badInput, .unreachable: "That didn't send. Try again."
        }
    }
}

/// One screenshot on offer: from today's library (loaded at send) or picked (already JPEG).
struct FeedbackShot: Identifiable {
    let id: String
    let thumbnail: Image
    let data: Data?
}

private struct FeedbackTile: View {
    let shot: FeedbackShot
    let isOn: Bool
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            shot.thumbnail
                .resizable()
                .scaledToFill()
                .frame(width: FeedbackMetrics.tileWidth, height: FeedbackMetrics.tileHeight)
                .clipShape(.rect(cornerRadius: FeedbackMetrics.tileCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: FeedbackMetrics.tileCorner)
                        .strokeBorder(
                            isOn ? palette.solid : palette.hairline, lineWidth: isOn ? FeedbackMetrics.ring : 1
                        )
                }
                .overlay(alignment: .bottomTrailing) { mark.padding(FeedbackMetrics.markInset) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screenshot")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("feedback.screenshot")
    }

    @ViewBuilder private var mark: some View {
        if isOn {
            AteIcon.check.view(size: FeedbackMetrics.checkGlyph)
                .foregroundStyle(palette.inverted)
                .frame(width: FeedbackMetrics.mark, height: FeedbackMetrics.mark)
                .background(palette.solid, in: .circle)
        } else {
            Circle()
                .strokeBorder(AteColor.paper, lineWidth: 2)
                .frame(width: FeedbackMetrics.mark, height: FeedbackMetrics.mark)
        }
    }
}

/// What goes with the report that the server cannot know.
enum FeedbackDevice {
    static var build: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleVersion"] as? String) ?? "?"
    }

    /// The hardware identifier, e.g. `iPhone18,1`.
    static var model: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "iPhone"
        }
    }

    static var os: String { "iOS \(UIDevice.current.systemVersion)" }

    /// The fine print: `Build 162 · iPhone18,1 · iOS 26.1`.
    static var summary: String { "Build \(build) · \(model) · \(os)" }
}

/// A screenshot as the report carries it: JPEG, at most 1600 on its longest edge (well under the
/// bucket's 3 MB).
enum FeedbackImage {
    static let longest: CGFloat = 1600
    static let quality: CGFloat = 0.75

    static func jpeg(from data: Data) -> Data? {
        guard let image = ImageProcessing.thumbnail(from: data, maxPixel: longest) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }
}

enum FeedbackMetrics {
    static let gap: CGFloat = 14
    static let lines = 5
    static let fieldPadding: CGFloat = 14
    static let fieldCorner: CGFloat = 22
    static let tileWidth: CGFloat = 72
    static let tileHeight: CGFloat = 156
    static let tileCorner: CGFloat = 14
    static let tileGap: CGFloat = 10
    static let ring: CGFloat = 3
    static let mark: CGFloat = 24
    static let markInset: CGFloat = 6
    static let checkGlyph: CGFloat = 14
    static let plusGlyph: CGFloat = 22
    static let todayLimit = 6
}

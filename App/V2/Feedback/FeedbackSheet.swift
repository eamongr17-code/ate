import AteKit
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

/// **Report a bug** (`design/rebuild/feedback.html` C–E; retitled, a how-to line added and today's
/// screenshots dropped on Eamon's ask, 22 Oct) — the Journal's bug, for testers. Close top left,
/// the send arrow top right, the title, the words. Under them the photos the tester added (tap one to
/// take it off) and the + that opens the picker. Three at most. The build and device go with it, in
/// fine print so the tester can see them. Sent, the sheet drops with a success haptic; offline, the
/// report waits in the outbox and sends itself. Fitted to its content, so the keyboard lifts the whole
/// sheet and never pushes the corner row off the top.
struct FeedbackSheet: View {
    let app: AppModel
    /// Called as the sheet goes: the Journal shows "Report sent" while it sends.
    var onSent: () -> Void = {}

    @State private var words = ""
    @State private var shots: [FeedbackShot] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var refusal: String?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.atePalette) private var palette

    private var canSend: Bool { FeedbackRules.canSend(words) && isSending == false }

    var body: some View {
        AteSheetScaffold(
            title: "Report a bug",
            primary: AteSheetPrimary(
                icon: .arrowUp, label: "Send", isEnabled: canSend, isBusy: isSending, action: send
            )
        ) {
            VStack(alignment: .leading, spacing: FeedbackMetrics.gap) {
                Text(Self.howTo)
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                field
                if let refusal {
                    Text(refusal)
                        .ateText(.meta)
                        .foregroundStyle(AteColor.coral)
                }
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
                    FeedbackTile(shot: shot) { remove(shot) }
                }
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(1, FeedbackRules.screenshotCap - shots.count),
                    matching: .images
                ) {
                    AteIcon.compose.view(size: FeedbackMetrics.plusGlyph)
                        .foregroundStyle(palette.muted)
                        .frame(width: FeedbackMetrics.tileWidth, height: FeedbackMetrics.tileHeight)
                        .overlay {
                            RoundedRectangle(cornerRadius: FeedbackMetrics.tileCorner)
                                .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                }
                .disabled(shots.count >= FeedbackRules.screenshotCap)
                .accessibilityLabel("Add photos")
                .accessibilityIdentifier("feedback.addPhotos")
            }
            .padding(FeedbackMetrics.ring)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func remove(_ shot: FeedbackShot) {
        shots.removeAll { $0.id == shot.id }
        AteHaptics.tick()
    }

    // MARK: - Photos

    /// From the picker: decoded, downscaled, attached straight away.
    private func take(_ items: [PhotosPickerItem]) async {
        pickerItems = []
        for item in items where shots.count < FeedbackRules.screenshotCap {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = FeedbackImage.jpeg(from: data),
                  let image = UIImage(data: jpeg) else { continue }
            shots.append(FeedbackShot(id: UUID().uuidString, thumbnail: Image(uiImage: image), data: jpeg))
        }
    }

    // MARK: - Send

    /// Kept on disk, then the sheet goes at once with the toast; the outbox sends it behind, and
    /// keeps it through a dropped connection (Eamon, 22 Oct: never wait on the upload).
    private func send() {
        guard canSend else { return }
        isSending = true
        isFocused = false
        let report = FeedbackReport(
            body: words, screenshots: shots.map(\.data), build: FeedbackDevice.build,
            device: FeedbackDevice.model, osVersion: FeedbackDevice.os, screens: ScreenTrail.app.screens
        )
        let outbox = app.services.feedback
        Task {
            do {
                try await outbox.post(report)
            } catch {
                AteHaptics.refused()
                refusal = "That didn't save. Try again."
                isSending = false
                return
            }
            app.services.analytics(FeedbackEvents.sent(screenshots: report.screenshots.count, queued: false))
            AteHaptics.success()
            onSent()
            dismiss()
            await outbox.flush()
        }
    }
}

/// One added photo, already JPEG.
struct FeedbackShot: Identifiable {
    let id: String
    let thumbnail: Image
    let data: Data
}

private struct FeedbackTile: View {
    let shot: FeedbackShot
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
                        .strokeBorder(palette.hairline, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) { mark.padding(FeedbackMetrics.markInset) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove photo")
        .accessibilityIdentifier("feedback.photo")
    }

    private var mark: some View {
        AteIcon.close.view(size: FeedbackMetrics.checkGlyph)
            .foregroundStyle(palette.inverted)
            .frame(width: FeedbackMetrics.mark, height: FeedbackMetrics.mark)
            .background(palette.solid, in: .circle)
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
    static let lines = 4
    static let fieldPadding: CGFloat = 14
    static let fieldCorner: CGFloat = 22
    static let tileWidth: CGFloat = 72
    static let tileHeight: CGFloat = 72
    static let tileCorner: CGFloat = 14
    static let tileGap: CGFloat = 10
    static let ring: CGFloat = 3
    static let mark: CGFloat = 24
    static let markInset: CGFloat = 6
    static let checkGlyph: CGFloat = 14
    static let plusGlyph: CGFloat = 22
}

import AteKit
import ImageIO
import SwiftUI
import UIKit

/// How big a photo is drawn, which decides what is fetched and how much of it is decoded.
///
/// A squircle in a list is 56–100pt: it asks for the `_t.jpg` beside the photo, and a 3× screen needs
/// no more than ~360px of it. The entry's collage and a dish hero are the full photo cut down to
/// ~1200px. Only the full-screen viewer, where the photo can be pinched, decodes it whole.
enum AtePhotoSize: String, Sendable, Hashable, CaseIterable {
    case thumbnail
    case large
    case full

    /// The longest side a decoded image is allowed, in pixels.
    var maxPixel: CGFloat {
        switch self {
        case .thumbnail: 360
        case .large: 1200
        case .full: 3000
        }
    }

    /// The size a tile of this side asks for. Anything a thumbnail would have to stretch to fill is
    /// a large photo.
    static func forSide(_ side: CGFloat) -> AtePhotoSize {
        side <= 120 ? .thumbnail : .large
    }

    /// Smaller copies that can stand in while this one arrives — the viewer opens on the collage's
    /// picture rather than on black.
    var standIns: [AtePhotoSize] {
        switch self {
        case .thumbnail: []
        case .large: [.thumbnail]
        case .full: [.large, .thumbnail]
        }
    }
}

/// **Every photo the app draws comes through here**: a memory cache of decoded images, a disk cache
/// of the bytes, one request per photo however many tiles ask for it, and thumbnails with a
/// fallback.
///
/// - **Memory** holds decoded, down-sampled images keyed by address *and* size, so a tile that is
///   redrawn — a bookmark flipping on the card it sits on — gets its picture back synchronously and
///   never flashes its placeholder.
/// - **Disk** (`Caches/ate-photos`) holds a thumbnail's small JPEG and a photo's original bytes, keyed
///   by a digest of the address. Uploads are immutable (a new photo is a new path), so a file never
///   goes stale; the folder is trimmed oldest-first when it passes its budget, and the system may
///   clear it at will.
/// - **Thumbnails** are asked for first (`<path minus extension>_t.jpg`); a photo without one (every
///   upload before round 3) falls back to the full image, cut down on the phone and filed under the
///   thumbnail's key, so the 404 is paid once.
final class AteImagePipeline: @unchecked Sendable {
    static let shared = AteImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let directory: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// How many callers are waiting on each request. When the last one goes away (its row scrolled
    /// off), the request is cancelled rather than finishing for nobody.
    private var waiters: [String: Int] = [:]
    /// Bytes written since the folder was last trimmed; past ``trimEvery`` a trim runs, so the cap
    /// holds during a long session and not only at launch.
    private var writtenSinceTrim = 0
    private var isTrimming = false

    /// The disk budget, and what a trim brings it back to.
    private static let diskLimit = 300 * 1024 * 1024
    private static let diskTarget = 200 * 1024 * 1024
    private static let trimEvery = 16 * 1024 * 1024

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        // The disk cache below is the cache: a second copy in URLCache would only double the bytes.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ate-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory
        Task.detached(priority: .background) { Self.trim(directory) }
    }

    // MARK: - Reading

    /// A picture that is already decoded, or nothing — never a wait. What a tile starts from.
    func cached(_ url: URL, size: AtePhotoSize) -> UIImage? {
        if let bundled = Self.bundled(url) { return bundled }
        return memory.object(forKey: Self.memoryKey(url, size) as NSString)
    }

    /// The best picture on hand for a size: its own, or a smaller one standing in.
    func bestCached(_ url: URL, size: AtePhotoSize) -> (image: UIImage, isFinal: Bool)? {
        if let own = cached(url, size: size) { return (own, true) }
        for standIn in size.standIns {
            if let image = cached(url, size: standIn) { return (image, false) }
        }
        return nil
    }

    /// The picture, from memory, disk or the network — one request however many callers ask.
    /// `nil` only when there is no picture to be had (a dead URL, no connection and no copy).
    func image(_ url: URL, size: AtePhotoSize, priority: TaskPriority = .userInitiated) async -> UIImage? {
        if let hit = cached(url, size: size) { return hit }
        let key = Self.memoryKey(url, size)
        let task: Task<UIImage?, Never> = lock.withLock {
            waiters[key, default: 0] += 1
            // A request its last waiter abandoned is not joined: it is on its way to nothing.
            if let running = inFlight[key], running.isCancelled == false { return running }
            let started = Task.detached(priority: priority) { [self] in
                await load(url, size: size)
            }
            inFlight[key] = started
            return started
        }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: { [self] in
            // The row that wanted it scrolled away. Only the last waiter cancels the fetch — a tile
            // still on screen asking for the same photo keeps it alive.
            lock.withLock {
                if waiters[key] == 1 { inFlight[key]?.cancel() }
            }
        }
        lock.withLock {
            let left = (waiters[key] ?? 1) - 1
            waiters[key] = left > 0 ? left : nil
            if left <= 0, inFlight[key] == task { inFlight[key] = nil }
        }
        return image
    }

    /// Warms the caches for photos about to scroll into view, at low priority. **Awaited from the
    /// row's own `.task`**, so when the row scrolls away the prefetch is cancelled with it and its
    /// fetches stop, instead of finishing for rows nobody is going to see.
    func prefetch(_ addresses: [String], size: AtePhotoSize) async {
        await withTaskGroup(of: Void.self) { group in
            for address in addresses {
                guard let url = URL(string: address), cached(url, size: size) == nil else { continue }
                group.addTask(priority: .utility) { [self] in
                    _ = await image(url, size: size, priority: .utility)
                }
            }
        }
    }

    // MARK: - Loading

    private func load(_ url: URL, size: AtePhotoSize) async -> UIImage? {
        let memoryKey = Self.memoryKey(url, size) as NSString
        let decoded: UIImage?
        switch size {
        case .thumbnail:
            decoded = await loadThumbnail(url)
        case .large, .full:
            decoded = await original(url).flatMap { Self.decode($0, maxPixel: size.maxPixel) }
        }
        if let decoded {
            memory.setObject(decoded, forKey: memoryKey, cost: Self.cost(of: decoded))
        }
        return decoded
    }

    /// The small copy: on disk; else the `_t.jpg`; else the original, cut down here and filed as
    /// the thumbnail so the fallback is paid once.
    private func loadThumbnail(_ url: URL) async -> UIImage? {
        let file = diskFile(url.absoluteString, kind: "thumb")
        if let data = readDisk(file) { return Self.decode(data, maxPixel: AtePhotoSize.thumbnail.maxPixel) }
        // An original already on disk (the viewer opened this photo) is a free thumbnail.
        let originalFile = diskFile(url.absoluteString, kind: "original")
        if let data = readDisk(originalFile) { return cutDownAndFile(data, to: file) }
        if let thumbnail = PhotoAddress.thumbnailURL(for: url), let data = await fetch(thumbnail),
           let image = Self.decode(data, maxPixel: AtePhotoSize.thumbnail.maxPixel) {
            writeDisk(data, to: file)
            return image
        }
        guard let data = await original(url) else { return nil }
        return cutDownAndFile(data, to: file)
    }

    private func cutDownAndFile(_ data: Data, to file: URL) -> UIImage? {
        guard let image = Self.decode(data, maxPixel: AtePhotoSize.thumbnail.maxPixel) else { return nil }
        if let small = image.jpegData(compressionQuality: 0.85) { writeDisk(small, to: file) }
        return image
    }

    /// The photo's own bytes: on disk, or fetched and filed.
    private func original(_ url: URL) async -> Data? {
        let file = diskFile(url.absoluteString, kind: "original")
        if let data = readDisk(file) { return data }
        guard let data = await fetch(url) else { return nil }
        writeDisk(data, to: file)
        return data
    }

    private func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.isEmpty == false else { return nil }
        return data
    }

    // MARK: - Disk

    private func diskFile(_ address: String, kind: String) -> URL {
        directory.appendingPathComponent(PhotoAddress.cacheKey(for: "\(kind)|\(address)"))
    }

    private func readDisk(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), data.isEmpty == false else { return nil }
        // Touched, so the trim keeps what is still being looked at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    private func writeDisk(_ data: Data, to file: URL) {
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let shouldTrim: Bool = lock.withLock {
            writtenSinceTrim += data.count
            guard writtenSinceTrim >= Self.trimEvery, isTrimming == false else { return false }
            writtenSinceTrim = 0
            isTrimming = true
            return true
        }
        guard shouldTrim else { return }
        let directory = directory
        Task.detached(priority: .background) { [self] in
            Self.trim(directory)
            lock.withLock { isTrimming = false }
        }
    }

    /// Oldest first, until the folder is back under its target.
    private static func trim(_ directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        struct Filed {
            let url: URL
            let size: Int
            let touched: Date
        }
        let described = files.compactMap { file -> Filed? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return Filed(url: file, size: values.fileSize ?? 0, touched: values.contentModificationDate ?? .distantPast)
        }
        var total = described.reduce(0) { $0 + $1.size }
        guard total > diskLimit else { return }
        for file in described.sorted(by: { $0.touched < $1.touched }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= diskTarget { break }
        }
    }

    // MARK: - Decoding

    /// Decoded straight to the size it is drawn at — a 12MP photo in an 80pt tile is 48MB of pixels
    /// otherwise — with its orientation applied.
    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func memoryKey(_ url: URL, _ size: AtePhotoSize) -> String {
        "\(size.rawValue)|\(url.absoluteString)"
    }

    /// The prototype photos, for `-ate-preview-data`: `asset://ragu` is the design's own fixture;
    /// `preview://<entry>/<n>` is what the in-memory service mints when a written entry's photos
    /// "upload", so a drive sees food rather than grey squares. Debug only.
    static func bundled(_ url: URL) -> UIImage? {
        #if DEBUG
        switch url.scheme {
        case "asset":
            return url.host().flatMap { UIImage(named: "Photos/\($0)") }
        case "preview":
            let index = Int(url.lastPathComponent) ?? 0
            return UIImage(named: "Photos/\(bundledNames[abs(index) % bundledNames.count])")
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static let bundledNames = ["ragu", "prawn", "tiramisu", "sushi", "burger", "pizza", "cake", "penne"]
    #endif
}

/// **Warming the rows below.** As each slip appears, the photos of the next few are fetched and
/// decoded at the size their cluster draws them, so they are already there when they scroll in.
@MainActor
enum AtePrefetch {
    /// Await it from the row's own `.task`: the row scrolling away cancels it.
    static func photos(after entry: EntryCard, in entries: [EntryCard]) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        await AteImagePipeline.shared.prefetch(PhotoAddress.upcoming(in: entries, after: index), size: .thumbnail)
    }
}

/// **A photo from the network, drawn.** A still placeholder tile in the surface's field colour —
/// never a spinner, never a shimmer — that the picture fades into when it arrives. A picture that is
/// already decoded is there on the first frame, with no fade: redrawing a card must not replay its
/// photos arriving.
struct AteRemotePhoto: View {
    let url: URL
    var size: AtePhotoSize = .large
    var contentMode: ContentMode = .fill
    /// What stands in while it loads. `nil` is the surface's field colour.
    var placeholder: Color?
    /// A dish's photo that will not load becomes its letter tile rather than a blank square.
    var failure: DishLetter?

    @State private var shown: Shown?
    @State private var didFail = false
    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Shown: Equatable {
        let url: URL
        let image: UIImage
        let isFinal: Bool
    }

    init(
        url: URL,
        size: AtePhotoSize = .large,
        contentMode: ContentMode = .fill,
        placeholder: Color? = nil,
        failure: DishLetter? = nil
    ) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.failure = failure
        _shown = State(initialValue: AteImagePipeline.shared.bestCached(url, size: size).map {
            Shown(url: url, image: $0.image, isFinal: $0.isFinal)
        })
    }

    var body: some View {
        ZStack {
            if didFail, let failure {
                DishLetterTile(dish: failure)
            } else {
                placeholder ?? palette.field
            }
            if let current {
                Image(uiImage: current.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: TaskKey(url: url, size: size)) { await load() }
    }

    /// Only ever the picture for *this* address: a recycled view must not show the last one's.
    private var current: Shown? {
        guard let shown, shown.url == url else { return nil }
        return shown
    }

    private struct TaskKey: Equatable {
        let url: URL
        let size: AtePhotoSize
    }

    private func load() async {
        if let current, current.isFinal { return }
        if current == nil, let standIn = AteImagePipeline.shared.bestCached(url, size: size) {
            shown = Shown(url: url, image: standIn.image, isFinal: standIn.isFinal)
            if standIn.isFinal { return }
        }
        didFail = false
        let requested = url
        let image = await AteImagePipeline.shared.image(requested, size: size)
        guard Task.isCancelled == false, requested == url else { return }
        guard let image else {
            if current == nil { didFail = true }
            return
        }
        // A stand-in swaps for the real thing in place; only a picture arriving on an empty tile
        // fades in.
        let fades = current == nil && reduceMotion == false
        withAnimation(fades ? .easeOut(duration: 0.22) : nil) {
            shown = Shown(url: requested, image: image, isFinal: true)
        }
    }
}

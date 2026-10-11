import Foundation
import Observation

/// **The share card** (`design/rebuild/share-to-ate.html`): a post shared in from another app, read,
/// and offered as a dish at a place to check and save. Nothing is saved without the Save tap.
///
/// The card rises reading; `read-share` fills the Dish and the Place (a Google match is turned into a
/// real place first, the place sheet's own way); a failed read leaves both empty and still saveable
/// by hand. Save needs a dish and a real place, writes `add_own_save` with the link it came from,
/// and the card says Saved.
@MainActor
@Observable
public final class ShareCardModel {
    public enum Phase: Sendable, Equatable {
        /// Waiting on `read-share`.
        case reading
        /// The fields are the person's to check.
        case ready
        /// No session on this phone: "Open Ate to sign in", nothing else.
        case signedOut
        /// Written. The card shows its tick and closes.
        case saved
    }

    public private(set) var phase: Phase = .reading
    /// The post, as shared (and, once read, the server's canonical link).
    public private(set) var link: String?
    public private(set) var source: OwnSaveSource = .manual
    public private(set) var author: String?
    public private(set) var caption: String?
    public private(set) var thumbnailURL: URL?
    public var dish = "" {
        didSet { if dish != oldValue, phase == .ready { isEdited = true } }
    }
    /// The place, once it is one the save can carry (or, while a Google match resolves, its name).
    public private(set) var place: PlaceRef?
    /// The suburb or city under a suggested place's name.
    public private(set) var placeDetail: String?
    /// A Google match is being turned into a real place.
    public private(set) var isResolvingPlace = false
    /// The place sheet's first query: the venue as the post named it.
    public private(set) var placeQuery = ""
    public private(set) var isSaving = false
    /// The save was refused — said once, in the app's one failure alert.
    public var failure: ActionFailure?
    /// The dish or the place was changed by hand.
    public private(set) var isEdited = false

    @ObservationIgnored private let reader: any ReadSharing
    @ObservationIgnored private let saves: any OwnSaving
    @ObservationIgnored private let places: any PlaceDirectory
    @ObservationIgnored private let isSignedIn: Bool
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let onSaved: @MainActor () -> Void
    /// Bumped by every change of place, so a slow Google resolve never overwrites a pick made since.
    @ObservationIgnored private var placeGeneration = 0

    public init(
        reader: any ReadSharing,
        saves: any OwnSaving,
        places: any PlaceDirectory,
        isSignedIn: Bool,
        analytics: @escaping AnalyticsRecorder = { _ in },
        onSaved: @escaping @MainActor () -> Void = {}
    ) {
        self.reader = reader
        self.saves = saves
        self.places = places
        self.isSignedIn = isSignedIn
        self.analytics = analytics
        self.onSaved = onSaved
    }

    // MARK: - What the card shows

    /// "@sydneyeats on TikTok".
    public var sourceTitle: String {
        OwnSaveSourceLine.title(source: source, url: link, author: author)
    }

    /// The caption in quotes, or the link.
    public var sourceDetail: String? {
        OwnSaveSourceLine.detail(url: link, caption: caption)
    }

    /// What Save writes, when there is enough to write: a dish name and a real place.
    public var draft: OwnSaveDraft? {
        guard let place, let id = place.id else { return nil }
        let draft = OwnSaveDraft(
            dishName: dish, restaurantID: id, restaurantName: place.name,
            link: link, author: author, caption: caption
        )
        return draft.trimmedDishName == nil ? nil : draft
    }

    public var canSave: Bool { phase == .ready && isSaving == false && draft != nil }

    // MARK: - Reading

    /// Reads the shared link. `link` is the first https link the share sheet handed over; `text` any
    /// words that came with it.
    public func start(link shared: URL?, text: String?) async {
        guard isSignedIn else {
            signOut()
            return
        }
        link = shared?.absoluteString
        source = .of(link: link)
        guard let shared else {
            phase = .ready
            analytics(ShareInEvents.read(
                source: source, outcome: .failed, dish: false, place: .unmatched, reason: "no_link"
            ))
            return
        }
        let result: ReadShareResult
        do {
            result = try await reader.read(url: shared, text: text)
        } catch ReadShareError.notAuthenticated {
            signOut()
            return
        } catch {
            phase = .ready
            let reason = (error as? ReadShareError)?.reason ?? "error"
            analytics(ShareInEvents.read(
                source: source, outcome: .failed, dish: false, place: .unmatched, reason: reason
            ))
            return
        }
        apply(result)
        phase = .ready
        let match: ShareInEvents.PlaceMatch = result.place?.restaurantID != nil
            ? .local : (result.place?.googlePlaceID != nil ? .google : .unmatched)
        let suggested = result.dish != nil || match != .unmatched
        analytics(ShareInEvents.read(
            source: source, outcome: suggested ? .suggested : .empty, dish: result.dish != nil, place: match
        ))
        if let suggestion = result.place?.suggestion, suggestion.restaurantID == nil {
            await resolve(suggestion, detail: result.place?.locality)
        }
    }

    private func apply(_ result: ReadShareResult) {
        link = result.url
        source = result.source
        author = result.author
        caption = result.caption
        thumbnailURL = result.thumbnailURL.flatMap { OwnSaveDraft.httpsURL($0) }
        dish = result.dish ?? ""
        placeQuery = result.placeQuery ?? result.place?.name ?? ""
        if let place = result.place {
            self.place = PlaceRef(id: place.restaurantID, name: place.name)
            placeDetail = place.locality
        }
    }

    /// A Google match becomes a restaurants row through the place sheet's own resolve. No row, no
    /// place: the field goes back to "Find the place" rather than offering one that attaches nothing.
    private func resolve(_ suggestion: PlaceSuggestion, detail: String?) async {
        placeGeneration += 1
        let generation = placeGeneration
        isResolvingPlace = true
        let resolved = try? await places.resolve(suggestion)
        guard generation == placeGeneration else { return }
        isResolvingPlace = false
        if let resolved, resolved.id != nil {
            place = resolved
            placeDetail = detail
        } else {
            place = nil
            placeDetail = nil
        }
    }

    private func signOut() {
        phase = .signedOut
        analytics(ShareInEvents.signedOut())
    }

    // MARK: - The person's changes

    /// A place picked on the place sheet — already a real row.
    public func pick(_ picked: PlaceRef) {
        placeGeneration += 1
        isResolvingPlace = false
        place = picked
        placeDetail = nil
        isEdited = true
    }

    /// Writes the save. `true` once it is in Saved.
    @discardableResult
    public func save() async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await saves.add(draft)
        } catch {
            failure = .addOwnSave
            return false
        }
        analytics(OwnSaveEvents.added(source: draft.source, origin: .shareExtension))
        onSaved()
        phase = .saved
        return true
    }

    /// The card was closed. Counted only when nothing was saved.
    public func dismissed() {
        guard phase == .ready || phase == .reading else { return }
        analytics(ShareInEvents.dismissed(source: source, edited: isEdited))
    }
}

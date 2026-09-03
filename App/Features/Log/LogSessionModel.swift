import AteKit
import Foundation
import SwiftUI

/// Where the sheet was opened from (§1.1). The entry decides which step is on screen first and
/// nothing else — every path converges on the same canvas.
enum LogEntry: Hashable {
    /// The `+` tab. Nothing pre-resolved: opens at WHERE.
    case tab
    /// Restaurant detail → "Log a dish". Opens at WHAT.
    case restaurant(SittingRestaurant)
    /// Dish detail → "Log this". Opens at the canvas with one unrated card.
    case dish(restaurant: SittingRestaurant, dishID: UUID, dishName: String)
    /// The §7 Continue row. Opens at the canvas, restored.
    case resume

    var telemetryKind: LogEntryKind {
        switch self {
        case .tab: .tab
        case .restaurant: .restaurant
        case .dish: .dish
        case .resume: .resume
        }
    }
}

/// The whole log session's state and behaviour: one restaurant, n dish drafts, one post, one receipt.
///
/// The views under `Features/Log` are thin by design — every rule the spec names (duplicate guard,
/// post gate, draft policy, when the funnel fires) is either here or, where it is pure, in AteKit's
/// ``SittingState``. This type is the seam between the two: it owns the async work (photo uploads,
/// the batched insert, the draft file) and nothing else.
@MainActor
@Observable
final class LogSessionModel {
    // MARK: Observable state

    private(set) var sitting: SittingState?
    private(set) var isPosting = false
    /// §6.4: shown as a banner on the canvas, never as an alert.
    private(set) var postFailureMessage: String?
    /// Non-nil once the sitting has been posted — the receipt's content.
    private(set) var receipt: ReceiptModel?
    private(set) var postedReviews: [Review] = []

    /// The posted rows **plus the names they were posted under** — what the host needs to put this
    /// sitting on the diary the instant the sheet leaves (§7.4).
    ///
    /// The rows alone can't do it: a ``Review`` carries UUIDs, and for a dish created ninety seconds
    /// ago there is nowhere on the client to look its name up. The canvas has known it all along;
    /// this is the canvas saying so on the way out, instead of the diary paying for a round trip to
    /// be told what was already on screen.
    var postedSitting: PostedSitting? {
        guard let sitting, !postedReviews.isEmpty else { return nil }
        return PostedSitting(reviews: postedReviews, sitting: sitting)
    }

    /// §5.1: "Posted without the photo" — a quiet notice, not an error.
    private(set) var postedWithoutPhoto = false
    /// Which card to flash/scroll to (a duplicate pick, or the first unrated card on a blocked post).
    var highlightedCardID: UUID?
    /// Bumped to fire the §2.4 wiggle on ``highlightedCardID``.
    private(set) var wiggleTrigger = 0
    /// The card whose photo picker is open, if any.
    var photoPickerCardID: UUID?
    /// §7: an unfinished sitting worth offering back, shown as the Continue row above WHERE.
    private(set) var resumableDraft: LogDraft?

    // MARK: Session

    let entry: LogEntry
    /// §2.6: read live rather than captured, so flipping the Debug toggle takes effect on the next
    /// dish instead of the next launch. In Release it is a constant.
    var variant: RatingPlacementVariant { LogDebugSettings.ratingPlacement }
    private let services: LogServices
    private let openedAt = Date()
    private var draftID: UUID
    private var photos: StagedPhotoStore
    private var uploads: [UUID: Task<Void, Never>] = [:]
    private var postedReviewIDs: Set<UUID> = []
    private var postAttempt = 0
    /// §6.4: sticky once a post has failed. Only a successful post clears it — never an ordinary
    /// "save draft", which is how a failed sitting used to get quietly stranded.
    private var needsPostRetry = false
    private var hasSentOpened = false
    private var hasEnded = false
    /// This session's claim on the draft it is editing, and on the one it is *offering* to resume.
    /// While either is held, the §6.4 foreground retry leaves that draft alone — otherwise it posts
    /// the sitting mid-edit and the funnel counts it twice (see ``LogDraftCheckout``). Held as
    /// tickets, not flags, so a sheet that dies without running `endSession` still lets go.
    private var sessionCheckout: LogDraftCheckoutTicket?
    private var resumableCheckout: LogDraftCheckoutTicket?

    init(entry: LogEntry, services: LogServices) {
        self.entry = entry
        self.services = services
        let draftID = UUID()
        self.draftID = draftID
        self.photos = StagedPhotoStore(draftID: draftID)

        switch entry {
        case .tab:
            break
        case .restaurant(let restaurant):
            sitting = SittingState(restaurant: restaurant, startedAt: openedAt)
        case .dish(let restaurant, let dishID, let dishName):
            var state = SittingState(restaurant: restaurant, startedAt: openedAt)
            state.add(dishID: dishID, dishName: dishName)
            sitting = state
        case .resume:
            break  // restored in start(), which can report the draft's age
        }
    }

    var searchServices: SearchServices { services.search }

    /// Fires `log_opened` exactly once. Not in `init` — SwiftUI can build a `@State` initial value
    /// more than once, and the first step of a funnel must not be inflated.
    func start() {
        guard !hasSentOpened else { return }
        hasSentOpened = true

        // Even a brand-new sitting claims its own id: if its first post fails, the draft it writes
        // carries this id, and the retry must not fire while the sheet is still open on it.
        sessionCheckout = services.checkout.checkOut(draftID)

        switch entry {
        case .resume:
            if let draft = services.drafts.load() { restore(draft) }
        case .tab:
            // §7: offered as the Continue row on WHERE, never auto-restored — resuming someone
            // else's half-finished meal without asking is a good way to post the wrong dish.
            resumableDraft = services.drafts.load()
            // Claimed while it is on screen as the Continue row: the person may be about to tap it,
            // and a retry that posts it first would leave a row offering a sitting that's gone.
            resumableCheckout = resumableDraft.map { services.checkout.checkOut($0.id) }
        case .restaurant, .dish:
            break
        }
        services.telemetry.send(.opened(entry: entry.telemetryKind))
    }

    /// §7: the Continue row was tapped.
    func resumeDraft() {
        guard let draft = resumableDraft else { return }
        restore(draft)
        resumableDraft = nil
        // The session claim taken by `restore` supersedes this one; dropping it can't release the
        // draft, because the registry only honours a release from the ticket it is holding.
        resumableCheckout = nil
    }

    /// §7: the Continue row was swiped away.
    func discardResumableDraft() {
        let id = resumableDraft?.id
        resumableDraft = nil
        resumableCheckout = nil
        services.drafts.clear(draftID: id)
        if let id { StagedPhotoStore(draftID: id).removeAll() }
    }

    private func restore(_ draft: LogDraft) {
        draftID = draft.id
        // The session now edits *this* draft, so the claim moves with it.
        sessionCheckout = services.checkout.checkOut(draft.id)
        photos = StagedPhotoStore(draftID: draft.id)
        sitting = draft.sitting
        postedReviewIDs = Set(draft.postedReviewIDs)
        // A resumed sitting inherits its unfinished business: if its post failed before, it is still
        // pending until it succeeds, and the attempt count keeps counting.
        needsPostRetry = draft.needsPostRetry
        postAttempt = draft.postAttempts
        services.telemetry.send(.draftResumed(ageMinutes: draft.ageMinutes()))
    }

    // MARK: - [1] WHERE

    /// The restaurant is resolved once and becomes the session's title — §4.2's first move.
    func resolveRestaurant(_ picked: PickedRestaurant) {
        let restaurant = SittingRestaurant(id: picked.id, name: picked.name, suburb: picked.locality)
        if sitting == nil {
            sitting = SittingState(restaurant: restaurant, startedAt: openedAt)
        }
        services.telemetry.send(.whereResolved(
            source: services.provenance.takeWhereSource(),
            millisecondsFromOpen: Int(Date().timeIntervalSince(openedAt) * 1_000)
        ))
    }

    // MARK: - [2] WHAT

    /// Adds a picked dish to the sitting. Returns the card to scroll to — a new one, or the existing
    /// one when the §4.3 duplicate guard fires.
    @discardableResult
    func addDish(_ picked: PickedDish) -> UUID? {
        guard var state = sitting else { return nil }
        services.provenance.recordDishSelected(id: picked.id, wasCreated: picked.wasCreated)
        let outcome = state.add(dishID: picked.id, dishName: picked.name)
        sitting = state

        switch outcome {
        case .added(let cardID, let index):
            services.telemetry.send(.whatResolved(
                source: services.provenance.takeWhatSource(),
                dishIndex: index
            ))
            services.telemetry.send(.dishAdded(dishIndex: index))
            highlightedCardID = cardID
            return cardID
        case .duplicate(let cardID, _):
            // §4.3: no second card. The canvas flashes the one that's already there.
            highlightedCardID = cardID
            wiggleTrigger += 1
            return cardID
        case .atCapacity:
            return nil
        }
    }

    // MARK: - [3] Canvas

    func ratingBinding(for cardID: UUID) -> Binding<Rating?> {
        Binding(
            get: { [weak self] in self?.sitting?[cardID]?.score },
            set: { [weak self] value in self?.sitting?.setScore(value, for: cardID) }
        )
    }

    func noteBinding(for cardID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.sitting?[cardID]?.note ?? "" },
            set: { [weak self] value in self?.sitting?.setNote(value, for: cardID) }
        )
    }

    func recordRatingSet(_ value: Rating, method: LogRatingMethod) {
        services.telemetry.send(.ratingSet(value: value.value, method: method, variant: variant))
    }

    func clearRating(for cardID: UUID) {
        sitting?.setScore(nil, for: cardID)
    }

    func removeCard(_ cardID: UUID) {
        guard let index = sitting?.index(of: cardID) else { return }
        cancelUpload(for: cardID)
        removeStagedPhoto(for: cardID)
        sitting?.remove(cardID: cardID)
        services.telemetry.send(.dishRemoved(dishIndex: index))
    }

    func removeCards(atOffsets offsets: IndexSet) {
        for index in offsets.sorted() {
            services.telemetry.send(.dishRemoved(dishIndex: index))
        }
        guard let removed = sitting?.remove(atOffsets: offsets) else { return }
        for cardID in removed {
            cancelUpload(for: cardID)
            removeStagedPhoto(for: cardID)
        }
    }

    // MARK: - Photos (§5.1: the upload starts on pick, in the background)

    func attachPhoto(_ data: Data, to cardID: UUID) {
        guard let staged = photos.stage(data, cardID: cardID) else { return }
        sitting?.setPhoto(SittingPhoto(localFileName: staged.fileName), for: cardID)
        startUpload(of: staged.data, for: cardID)
    }

    func retryPhotoUpload(for cardID: UUID) {
        guard let fileName = sitting?[cardID]?.photo?.localFileName,
              let data = photos.data(for: fileName)
        else { return }
        sitting?.setPhotoUploadState(.uploading, for: cardID)
        startUpload(of: data, for: cardID)
    }

    func removePhoto(from cardID: UUID) {
        cancelUpload(for: cardID)
        removeStagedPhoto(for: cardID)
        sitting?.setPhoto(nil, for: cardID)
    }

    func photoURL(for cardID: UUID) -> URL? {
        sitting?[cardID]?.photo.map { photos.url(for: $0.localFileName) }
    }

    private func startUpload(of data: Data, for cardID: UUID) {
        uploads[cardID]?.cancel()
        uploads[cardID] = Task { [services, weak self] in
            do {
                let url = try await services.photos.upload(data, reviewID: cardID)
                guard !Task.isCancelled else { return }
                self?.sitting?.setPhotoUploadState(.uploaded(urlString: url.absoluteString), for: cardID)
            } catch {
                guard !Task.isCancelled else { return }
                // §3.5/§5.1: a failed upload is a retry affordance on the card; it never blocks Post.
                self?.sitting?.setPhotoUploadState(.failed, for: cardID)
            }
            self?.uploads[cardID] = nil
        }
    }

    private func cancelUpload(for cardID: UUID) {
        uploads[cardID]?.cancel()
        uploads[cardID] = nil
    }

    private func removeStagedPhoto(for cardID: UUID) {
        guard let fileName = sitting?[cardID]?.photo?.localFileName else { return }
        photos.remove(fileName: fileName)
    }

    // MARK: - [4] Post

    var postButtonTitle: String {
        guard let sitting else { return "Post" }
        if isPosting { return "Posting…" }
        if sitting.hasUploadInFlight { return "Uploading photo…" }
        return postFailureMessage == nil ? sitting.postButtonTitle : "Try again"
    }

    var canPost: Bool { sitting?.isEmpty == false && !isPosting }

    /// §4.3: tapping Post with an unrated card doesn't fire the post — it scrolls to the offender and
    /// wiggles it. No alert: the card already says what's missing.
    func post() async {
        guard let state = sitting, !isPosting else { return }
        guard state.isPostable else {
            highlightedCardID = state.firstUnratedCardID
            wiggleTrigger += 1
            return
        }

        LogHaptics.posted()
        isPosting = true
        postFailureMessage = nil
        postAttempt += 1
        defer { isPosting = false }

        do {
            let reviewerID = try await services.currentUserID()
            let rows = SittingPost.rows(
                from: state,
                reviewerID: reviewerID,
                alreadyPosted: postedReviewIDs
            )
            let inserted = try await services.poster.post(rows)
            postedReviews += inserted
            postedReviewIDs.formUnion(inserted.map(\.id))
            // The only thing that clears the flag: the rows actually landed.
            needsPostRetry = false
            postedWithoutPhoto = state.hasPhoto && rows.contains { $0.photoURLString == nil }

            services.telemetry.send(.posted(
                dishCount: state.dishes.count,
                hasNote: state.hasNote,
                hasPhoto: inserted.contains { $0.hasPhoto },
                secondsFromOpen: state.secondsFromOpen()
            ))

            receipt = ReceiptModel(sitting: state, author: await services.currentUser())
            services.telemetry.send(.receiptShown(dishCount: state.dishes.count))
            // The draft's job is done — but the staged photos stay until the sheet closes, because
            // the receipt renders from them (§5.4).
            services.drafts.clear(draftID: nil)
        } catch {
            postFailureMessage = "Couldn't post. Your dishes are saved."
            services.telemetry.send(.postFailed(
                reason: LogPostFailureReason.of(error),
                dishCount: state.dishes.count,
                attempt: postAttempt
            ))
            saveDraft(pendingPost: true)
        }
    }

    func localPhotoURL(forReceiptLine line: ReceiptModel.Line) -> URL? {
        line.photoFileName.map { photos.url(for: $0) }
    }

    func recordReceiptShared(activityType: String) {
        services.telemetry.send(.receiptShared(
            dishCount: receipt?.lines.count ?? 0,
            activityType: activityType
        ))
    }

    // MARK: - Drafts + leaving (§7)

    /// §7 dismissal guard: a bare, untouched sitting leaves silently.
    var hasContent: Bool { sitting?.hasContent == true && receipt == nil }

    /// Writes the current sitting as *the* draft.
    ///
    /// `pendingPost` can only ever raise the retry flag — never lower it. Tapping Cancel → "Save
    /// draft" after a failed post must not tell the retry runner there is nothing to retry, which is
    /// exactly how a failed sitting got stranded: saved, believed posted, never sent again. The
    /// in-memory flag below keeps this session honest; ``LogDraftStoring/save(_:)`` applies
    /// ``LogDraftPolicy`` under the seam, so a *different* writer can't strand it either.
    func saveDraft(pendingPost: Bool = false) {
        guard let sitting, receipt == nil else { return }
        needsPostRetry = needsPostRetry || pendingPost
        let draft = LogDraft(
            id: draftID,
            sitting: sitting,
            savedAt: Date(),
            postedReviewIDs: Array(postedReviewIDs),
            needsPostRetry: needsPostRetry,
            postAttempts: postAttempt
        )
        guard draft.isWorthKeeping else { return }
        services.drafts.save(draft)
    }

    /// §6.5: the draft is written whenever the app stops being active, so an interruption is not a
    /// decision the person has to make.
    func persistOnInterruption() {
        saveDraft()
    }

    func endSession(step: LogStep, savedDraft: Bool) {
        guard !hasEnded else { return }
        hasEnded = true
        for task in uploads.values { task.cancel() }
        uploads = [:]
        // Whatever this session was holding goes back now: if the draft it saved still needs a
        // post, the very next foreground is allowed to send it.
        releaseDraftCheckouts()

        if receipt == nil {
            services.telemetry.send(.abandoned(
                step: step,
                dishCount: sitting?.dishes.count ?? 0,
                savedDraft: savedDraft
            ))
        }
        if !savedDraft {
            photos.removeAll()
        }
    }

    func discardDraft() {
        services.drafts.clear(draftID: draftID)
        photos.removeAll()
    }

    /// Hands both draft claims back. Called from `endSession` and again when the sheet's view
    /// disappears, because a swipe-dismissed sheet runs neither Cancel nor Done. Dropping the
    /// tickets is all it takes; ARC does the same thing if this model is deallocated without anyone
    /// calling anything — which is the point of holding tickets rather than setting a flag.
    ///
    /// Safe to call early: the worst case is the pre-existing behaviour where a foreground retry
    /// posts a sitting the sheet still has open, which the database absorbs. Failing to call it can
    /// never strand a draft past this process.
    func releaseDraftCheckouts() {
        sessionCheckout = nil
        resumableCheckout = nil
    }
}

import Foundation
import Testing
@testable import AteKit

/// When you ate it, and which photo is which dish (13 Oct beta, design/rebuild/date-and-photos.html).
@Suite("Dates and photo matching")
struct DatesAndPhotosTests {
    private var melbourne: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: - The day

    @Test("a picked day keeps the entry's own time of day")
    func pickedDayKeepsTime() {
        let dinner = date("2026-10-13T09:30:00Z") // 20:30 in Melbourne
        let sunday = date("2026-10-11T02:00:00Z") // 13:00 Sunday in Melbourne
        let moved = EatenDay.moment(day: sunday, keepingTimeOf: dinner, calendar: melbourne)
        #expect(moved == date("2026-10-11T09:30:00Z"))
    }

    @Test("photos from different days: the earliest one's moment")
    func earliestPhoto() {
        let early = date("2026-10-10T08:00:00Z")
        #expect(EatenDay.fromPhotos([date("2026-10-11T08:00:00Z"), nil, early]) == early)
        #expect(EatenDay.fromPhotos([nil, nil]) == nil)
    }

    @Test("a photo's EXIF time, in its own offset when it has one")
    func exif() {
        let melbourneZone = TimeZone(identifier: "Australia/Melbourne")!
        #expect(EatenDay.exifDate("2026:10:11 19:42:05", offset: "+11:00") == date("2026-10-11T08:42:05Z"))
        #expect(EatenDay.exifDate("2026:10:11 19:42:05", timeZone: melbourneZone) == date("2026-10-11T08:42:05Z"))
        #expect(EatenDay.exifDate("2026:10:11 19:42:05", offset: "-05:00") == date("2026-10-12T00:42:05Z"))
        #expect(EatenDay.exifDate("not a date") == nil)
    }

    @Test("never in the future")
    func clamped() {
        let now = date("2026-10-13T09:00:00Z")
        #expect(EatenDay.clamped(date("2026-10-13T11:00:00Z"), now: now) == now)
        #expect(EatenDay.clamped(date("2026-10-12T11:00:00Z"), now: now) == date("2026-10-12T11:00:00Z"))
    }

    @Test("the pill: nothing for today, the day otherwise, the year only when it isn't this one")
    func label() {
        let now = date("2026-10-13T09:00:00Z")
        let locale = Locale(identifier: "en_AU")
        #expect(EatenDay.label(for: nil, now: now, calendar: melbourne, locale: locale) == nil)
        #expect(EatenDay.label(for: date("2026-10-13T01:00:00Z"), now: now, calendar: melbourne, locale: locale) == nil)
        let sunday = EatenDay.label(for: date("2026-10-11T09:00:00Z"), now: now, calendar: melbourne, locale: locale)
        #expect(sunday?.contains("Sun") == true)
        #expect(sunday?.contains("11") == true)
        #expect(sunday?.contains("2026") == false)
        let lastYear = EatenDay.label(for: date("2025-12-24T09:00:00Z"), now: now, calendar: melbourne, locale: locale)
        #expect(lastYear?.contains("2025") == true)
    }

    @Test("the pill: photos date a new entry, a pick wins over them, and Today is the default again")
    func choice() {
        let now = date("2026-10-13T09:00:00Z")
        var choice = EntryDateChoice()
        #expect(choice.photosDated([date("2026-10-13T02:00:00Z")], now: now, calendar: melbourne) == false)
        #expect(choice.eatenAt == nil)
        #expect(choice.photosDated([date("2026-10-11T08:00:00Z"), date("2026-10-12T08:00:00Z")],
                                   now: now, calendar: melbourne))
        #expect(choice.eatenAt == date("2026-10-11T08:00:00Z"))
        #expect(choice.source == .photos)
        #expect(choice.daysAgo(now: now, calendar: melbourne) == 2)

        choice.pick(date("2026-10-12T01:00:00Z"), now: now, calendar: melbourne)
        #expect(choice.source == .picked)
        #expect(choice.eatenAt == date("2026-10-12T08:00:00Z")) // the day picked, the photo's hour kept
        #expect(choice.photosDated([date("2026-10-01T08:00:00Z")], now: now, calendar: melbourne) == false)

        choice.pick(now, now: now, calendar: melbourne)
        #expect(choice.eatenAt == nil)
        #expect(choice.source == nil)
    }

    @Test("an edit opens on its own day, photos never move it, and only a real move counts")
    func editChoice() {
        let now = date("2026-10-13T09:00:00Z")
        let opened = date("2026-10-10T09:00:00Z")
        var choice = EntryDateChoice(editing: opened)
        #expect(choice.changed == false)
        #expect(choice.photosDated([date("2026-10-01T08:00:00Z")], now: now, calendar: melbourne) == false)
        choice.pick(now, now: now, calendar: melbourne)
        #expect(choice.changed)
        #expect(choice.eatenAt == now) // today on an edit is a real day, not "now later"
    }

    @Test("a draft written before the date pill still opens, dated now")
    func oldDraftDecodes() throws {
        let draft = EntryDraft(composition: EntryComposition(plain: "Gnocchi", spans: []))
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
        )
        json.removeValue(forKey: "eatenAt")
        json.removeValue(forKey: "isDatePicked")
        let decoded = try JSONDecoder().decode(EntryDraft.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.eatenAt == nil)
        #expect(decoded.isDatePicked == false)
    }

    @Test("a dated draft keeps its day and whether it was picked")
    func datedDraftRoundTrips() throws {
        let day = date("2026-10-11T09:30:00Z")
        let draft = EntryDraft(
            composition: EntryComposition(plain: "Gnocchi", spans: []), eatenAt: day, isDatePicked: true
        )
        let decoded = try JSONDecoder().decode(EntryDraft.self, from: JSONEncoder().encode(draft))
        #expect(abs(decoded.eatenAt!.timeIntervalSince(day)) < 0.001)
        #expect(decoded.isDatePicked)
    }

    // MARK: - An edit

    private func edit(
        photos: [EntryEdit.Photo]? = nil, original: [EntryCard.Photo] = [], body: String = "Gnocchi 4.0",
        opened: Date? = nil, eatenAt: Date? = nil
    ) -> EntryEdit {
        EntryEdit(
            entryID: UUID(), body: body, originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
            originalPhotos: original, photos: photos, originalBody: "Gnocchi 4.0",
            originalEatenAt: opened, eatenAt: eatenAt
        )
    }

    @Test("an edit that moves the day writes it; one that doesn't, doesn't")
    func editWritesDate() async throws {
        let opened = date("2026-10-13T09:30:00Z")
        let service = MatchRecorder()
        try await edit(opened: opened, eatenAt: date("2026-10-11T09:30:00Z")).save(to: service)
        #expect(service.dated == [date("2026-10-11T09:30:00Z")])

        let still = MatchRecorder()
        try await edit(opened: opened, eatenAt: opened.addingTimeInterval(0.4)).save(to: still)
        try await edit(opened: opened, eatenAt: nil).save(to: still)
        #expect(still.dated.isEmpty)
    }

    @Test("after an edit's re-sort the photos are paired again; a words-free, photo-free edit asks nothing")
    func editMatches() async throws {
        let photo = EntryCard.Photo(url: "https://x/a.jpg", position: 0)
        let resorted = MatchRecorder()
        let words = edit(photos: [.existing(url: photo.url)], original: [photo], body: "Gnocchi 4.5")
        await words.matchPhotos(on: resorted)
        #expect(resorted.matched.count == 1)

        let added = MatchRecorder()
        let photoOnly = edit(photos: [.existing(url: photo.url), .added(path: "/tmp/b.jpg")], original: [photo])
        #expect(photoOnly.skipsSort)
        await photoOnly.matchPhotos(on: added)
        #expect(added.matched.count == 1)

        let nothing = MatchRecorder()
        await edit(photos: [.existing(url: photo.url)], original: [photo]).matchPhotos(on: nothing)
        await edit(photos: nil, original: [], body: "Gnocchi 4.5").matchPhotos(on: nothing)
        #expect(nothing.matched.isEmpty)
    }

    // MARK: - Posting

    @Test("a new entry with photos is matched once its photos are up and its lines exist")
    func submissionMatches() async throws {
        let service = MatchRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        let id = UUID()
        await submission.finish(entryID: id, photoPaths: [file.path()])
        #expect(service.matched == [id])

        let wordsOnly = MatchRecorder()
        let plain = EntrySubmission(
            entries: wordsOnly, outbox: EntryOutbox(entries: wordsOnly, containerName: "Tests-\(UUID().uuidString)")
        )
        await plain.finish(entryID: UUID(), photoPaths: [])
        #expect(wordsOnly.matched.isEmpty)
    }

    // MARK: - Reading the pairs

    @Test("which dish each photo is: lines without a photo are left out")
    func reviewPhotoRows() throws {
        let a = UUID(), b = UUID()
        let json = """
        [{"id":"\(a.uuidString)","photo_url":"https://x/1.jpg"},{"id":"\(b.uuidString)","photo_url":null}]
        """
        #expect(try ReviewPhotoRow.map(from: Data(json.utf8)) == ["https://x/1.jpg": a])
    }

    @Test("the in-memory stand-in: a pick moves the photo, No dish clears it")
    func inMemoryPick() async throws {
        let service = InMemoryEntryService()
        let entry = UUID(), tiramisu = UUID(), pasta = UUID()
        try await service.setReviewPhoto(entryID: entry, photoURL: "p1", reviewID: tiramisu)
        try await service.setReviewPhoto(entryID: entry, photoURL: "p1", reviewID: pasta)
        #expect(try await service.photoDishes(entryID: entry) == ["p1": pasta])
        try await service.setReviewPhoto(entryID: entry, photoURL: "p1", reviewID: nil)
        #expect(try await service.photoDishes(entryID: entry).isEmpty)
    }

    @Test("events: a backdated entry and the two new corrections")
    func events() {
        let dated = EntryEvents.dated(source: .photos, daysAgo: 2)
        #expect(dated.name == "entry_dated")
        #expect(dated.parameters == ["source": "photos", "days_ago": "2"])
        #expect(EntryEvents.corrected(.date).parameters["part"] == "date")
        #expect(EntryEvents.corrected(.photo).parameters["part"] == "photo")
    }
}

/// Records the date writes and the match requests; everything else an edit or a post needs, answered.
final class MatchRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date] = []
    private var matches: [UUID] = []
    var dated: [Date] { lock.withLock { dates } }
    var matched: [UUID] { lock.withLock { matches } }

    func authorID() async throws -> UUID { ViewerProfile.preview.id }
    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func updateBody(entryID: UUID, body: String) async throws {}
    func attach(photo: EntryPhotoUpload) async throws {}
    func attachExisting(entryID: UUID, position: Int, url: String) async throws {}
    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {}
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 2, restaurantID: nil, didAttachPlace: false
        )
    }
    func setEntryDate(entryID: UUID, eatenAt: Date) async throws { lock.withLock { dates.append(eatenAt) } }
    func matchPhotos(entryID: UUID) async { lock.withLock { matches.append(entryID) } }
}

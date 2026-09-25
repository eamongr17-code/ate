import Foundation
import Testing

@testable import AteKit

/// The handle field's rules. They are the column's rules (`citext`, `[a-z0-9_]`, 1–30) expressed
/// once on the client, and every one of these cases is a way a field that did not enforce them
/// would produce a handle the unique index then refused.
@Suite("Handle — what the field may hold")
struct HandleNameTests {

    @Test("the @ is furniture, not input")
    func stripsTheAt() {
        #expect(HandleName.sanitise("@eamon") == "eamon")
        #expect(HandleName.sanitise("@@eamon") == "eamon")
        #expect(HandleName.display("eamon") == "@eamon")
    }

    @Test("username is citext, so the field folds case")
    func foldsCase() {
        #expect(HandleName.sanitise("Eamon") == "eamon")
        #expect(HandleName.isSame("Eamon", "eamon"))
    }

    @Test("only a-z, 0-9 and underscore survive")
    func keepsOnlyTheAlphabet() {
        #expect(HandleName.sanitise("eamon gracias") == "eamongracias")
        #expect(HandleName.sanitise("e.a-m'o+n!") == "eamon")
        #expect(HandleName.sanitise("ea_mon99") == "ea_mon99")
        #expect(HandleName.sanitise("éämon") == "mon")
    }

    @Test("30 characters, which is profiles_username_format")
    func capsAtThirty() {
        let long = String(repeating: "a", count: 40)
        #expect(HandleName.sanitise(long).count == 30)
        #expect(HandleName.isWellFormed(String(repeating: "a", count: 30)))
        #expect(HandleName.isWellFormed(String(repeating: "a", count: 31)) == false)
    }

    @Test("empty is not a handle")
    func rejectsEmpty() {
        #expect(HandleName.sanitise("@") == "")
        #expect(HandleName.isWellFormed("") == false)
    }

    @Test("the check is drawn for exactly one state")
    func onlyAvailableDrawsTheCheck() {
        #expect(HandleStatus.available.showsCheck)
        for status in [HandleStatus.empty, .malformed, .checking, .taken, .unknown] {
            #expect(status.showsCheck == false)
        }
    }

    @Test("a check that could not be made does not block Continue")
    func unknownStillContinues() {
        #expect(HandleStatus.unknown.allowsContinue)
        #expect(HandleStatus.available.allowsContinue)
        #expect(HandleStatus.taken.allowsContinue == false)
        #expect(HandleStatus.checking.allowsContinue == false)
        #expect(HandleStatus.empty.allowsContinue == false)
        #expect(HandleStatus.malformed.allowsContinue == false)
    }
}

/// The debounce, and the two races it exists to lose safely.
@Suite("Handle — when it asks the server")
@MainActor
struct HandleModelTests {
    /// Short enough to keep the suite fast, long enough that a burst really is one window.
    static let debounce = Duration.milliseconds(40)

    func model(
        _ account: InMemoryAccountService,
        current: String? = nil,
        events: EventLog? = nil
    ) -> HandleModel {
        let noop: AnalyticsRecorder = { _ in }
        let recorder: AnalyticsRecorder = if let events { events.recorder } else { noop }
        return HandleModel(
            account: account,
            analytics: recorder,
            current: current,
            isFirstRun: current == nil,
            debounce: Self.debounce
        )
    }

    /// Waits for the model to settle rather than sleeping a fixed amount — a fixed sleep is a
    /// flake on a loaded machine.
    func settle(_ model: HandleModel, until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the handle model never settled")
    }

    @Test("a burst of keystrokes is one round trip, for the last value")
    func debouncesToTheLastValue() async throws {
        let account = InMemoryAccountService(taken: [])
        let model = model(account)

        for text in ["e", "ea", "eam", "eamo", "eamon"] {
            model.type(text)
        }
        try await settle(model) { model.status == .available }

        #expect(account.checked == ["eamon"], "every keystroke asked the server")
    }

    @Test("a taken handle loses its check")
    func reportsTaken() async throws {
        let account = InMemoryAccountService(taken: ["taken"])
        let model = model(account)
        model.type("taken")
        try await settle(model) { model.status == .taken }
        #expect(model.status.showsCheck == false)
        #expect(model.canContinue == false)
    }

    @Test("an answer that lands after the field moved on is ignored")
    func ignoresALateAnswer() async throws {
        // "one" is free and "two" is taken. Typing them in that order with a pause between must
        // leave the field on the SECOND answer, whichever order the replies happen to land in.
        let account = InMemoryAccountService(taken: ["two"])
        let model = model(account)
        model.type("one")
        try await settle(model) { model.status == .available }
        model.type("two")
        try await settle(model) { model.status == .taken }
        #expect(account.checked == ["one", "two"])
        #expect(model.status == .taken)
    }

    @Test("illegal input never reaches the server")
    func neverChecksAMalformedHandle() async throws {
        let account = InMemoryAccountService(taken: [])
        let model = model(account)
        model.type("!!!")
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.status == .empty, "nothing legal was typed, so there is nothing to check")
        #expect(account.checked.isEmpty)
    }

    @Test("editing from Settings: your own handle is yours, with no round trip")
    func ownHandleIsAvailable() async throws {
        let account = InMemoryAccountService(taken: ["eamon"])
        let model = model(account, current: "eamon")
        #expect(model.typed == "eamon")
        #expect(model.status == .available)
        model.type("eamonn")
        try await settle(model) { model.status == .available }
        model.type("eamon")
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.status == .available)
        #expect(account.checked == ["eamonn"], "the server was asked about a handle we already own")
    }

    @Test("a check that fails leaves Continue alive")
    func failedCheckIsUnknown() async throws {
        let account = InMemoryAccountService(taken: [])
        account.failure = AteAPIError.notAuthenticated
        let model = model(account)
        model.type("eamon")
        try await settle(model) { model.status == .unknown }
        #expect(model.canContinue)
    }

    @Test("Continue writes the handle and reports it once")
    func savesAndReports() async throws {
        let events = EventLog()
        let account = InMemoryAccountService(taken: [])
        let model = model(account, events: events)
        model.type("eamon")
        try await settle(model) { model.status == .available }

        let saved = await model.save()
        #expect(saved == "eamon")
        #expect(account.profile.username == "eamon")
        #expect(events.names == ["handle_set"])
        #expect(events.first(named: "handle_set")?.parameters["is_first_run"] == "true")
    }

    @Test("a refused write keeps the screen, and says the handle went")
    func refusedWriteStays() async throws {
        let account = InMemoryAccountService(taken: [])
        let model = model(account)
        model.type("eamon")
        try await settle(model) { model.status == .available }
        account.failure = AteAPIError.notAuthenticated

        let saved = await model.save()
        #expect(saved == nil)
        #expect(model.didFailToSave)
        #expect(model.status == .taken)
    }

    @Test("an unchanged handle needs no write at all")
    func unchangedHandleIsAlreadyDone() async throws {
        let events = EventLog()
        let account = InMemoryAccountService(
            profile: AccountProfile(id: UUID(), username: "eamon"),
            taken: ["eamon"]
        )
        let model = model(account, current: "eamon", events: events)
        let saved = await model.save()
        #expect(saved == "eamon")
        #expect(events.names.isEmpty, "nothing was written, so nothing happened")
    }

    @Test("first run: keeping the handle the account came with still completes the funnel step")
    func firstRunKeepingTheSuggestionCounts() async throws {
        let events = EventLog()
        let account = InMemoryAccountService(profile: AccountProfile(id: UUID(), username: "eamon"))
        let model = HandleModel(
            account: account,
            analytics: events.recorder,
            current: "eamon",
            isFirstRun: true,
            debounce: Self.debounce
        )
        #expect(model.status == .available, "the account's own handle is drawn with its check")
        #expect(await model.save() == "eamon")
        #expect(account.checked.isEmpty, "no round trip for your own handle")
        #expect(events.names == ["handle_set"])
        #expect(events.first(named: "handle_set")?.parameters["is_first_run"] == "true")
    }
}

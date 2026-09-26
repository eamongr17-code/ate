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

    @Test("typing keeps what is illegal, so the field can say so; the @ and capitals fold away")
    func normaliseKeepsWhatWasTyped() {
        #expect(HandleName.normalise("@Eamon") == "eamon")
        #expect(HandleName.normalise("eamon gracias") == "eamon gracias")
        #expect(HandleName.normalise("e.amon") == "e.amon")
        #expect(HandleName.normalise(String(repeating: "a", count: 40)).count == 30)
        #expect(HandleName.isWellFormed(HandleName.normalise("e.amon")) == false)
    }

    @Test("checking, taken and malformed each carry their own mark")
    func marksAreDistinct() {
        #expect(HandleStatus.empty.mark == .none)
        #expect(HandleStatus.checking.mark == .checking)
        #expect(HandleStatus.unknown.mark == .checking)
        #expect(HandleStatus.available.mark == .available)
        #expect(HandleStatus.taken.mark == .taken)
        #expect(HandleStatus.malformed.mark == .malformed)
    }

    @Test("Continue waits for a handle that is well formed and known to be free")
    func onlyAvailableContinues() {
        #expect(HandleStatus.unknown.allowsContinue == false)
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

    @Test("illegal input is marked malformed and never reaches the server")
    func neverChecksAMalformedHandle() async throws {
        let account = InMemoryAccountService(taken: [])
        let model = model(account)
        model.type("eamon.gracias")
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.status == .malformed)
        #expect(model.canContinue == false)
        #expect(account.checked.isEmpty)
        #expect(await model.save() == nil)
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

    @Test("a check that fails keeps Continue off and asks again until it has an answer")
    func failedCheckRetries() async throws {
        let account = InMemoryAccountService(taken: [])
        account.failure = AteAPIError.notAuthenticated
        let model = HandleModel(
            account: account, current: nil, isFirstRun: true,
            debounce: Self.debounce, retry: Self.debounce
        )
        model.type("eamon")
        try await settle(model) { model.status == .unknown }
        #expect(model.canContinue == false)
        #expect(model.status.mark == .checking)
        account.failure = nil
        try await settle(model) { model.status == .available }
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

    @Test("a write that fails for any other reason keeps the handle's mark and can be tried again")
    func failedWriteIsRetryable() async throws {
        let account = InMemoryAccountService(taken: [])
        let model = model(account)
        model.type("eamon")
        try await settle(model) { model.status == .available }
        account.failure = AteAPIError.notAuthenticated

        #expect(await model.save() == nil)
        #expect(model.didFailToSave)
        #expect(model.status == .available, "offline is not a verdict on the handle")
        #expect(model.canContinue)

        model.acknowledgeSaveFailure()
        account.failure = nil
        #expect(await model.save() == "eamon")
    }

    @Test("only the unique index refusing is 'taken'")
    func uniquenessViolationIsTaken() async throws {
        // Free when checked; somebody takes it before Continue lands.
        let account = InMemoryAccountService(taken: [])
        let model = model(account)
        model.type("jessw")
        try await settle(model) { model.status == .available }
        account.take("jessw")

        #expect(await model.save() == nil)
        #expect(model.status == .taken)
        #expect(model.didFailToSave == false, "taken is its mark, not a save error")
        #expect(model.canContinue == false)
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

    @Test("first run: keeping your own derived handle writes nothing and reports nothing")
    func firstRunKeepingAHandleIsNotASet() async throws {
        let events = EventLog()
        let account = InMemoryAccountService(profile: AccountProfile(id: UUID(), username: "eamon"))
        let model = HandleModel(
            account: account, analytics: events.recorder, current: "eamon", isFirstRun: true,
            debounce: Self.debounce
        )
        #expect(model.status == .available)
        #expect(await model.save() == "eamon")
        #expect(events.names.isEmpty, "handle_set fires only on a real write")
    }

    @Test("first run never offers the server's placeholder: the field opens empty, Continue waits")
    func placeholderIsNotOffered() async throws {
        let events = EventLog()
        let account = InMemoryAccountService(profile: AccountProfile(id: UUID(), username: "ate1a2b3c4d"))
        let model = HandleModel(
            account: account, analytics: events.recorder, current: "ate1a2b3c4d", isFirstRun: true,
            debounce: Self.debounce
        )
        #expect(model.typed.isEmpty)
        #expect(model.canContinue == false)
        #expect(await model.save() == nil)
        model.type("eamon")
        try await settle(model) { model.status == .available }
        #expect(await model.save() == "eamon")
        #expect(events.names == ["handle_set"])
        #expect(try await account.account().username == "eamon")
    }

    @Test("from Settings, the placeholder is still your handle to keep")
    func settingsKeepsWhateverYouHave() {
        let model = HandleModel(
            account: InMemoryAccountService(), current: "ate1a2b3c4d", isFirstRun: false, debounce: Self.debounce
        )
        #expect(model.typed == "ate1a2b3c4d")
        #expect(model.status == .available)
    }
}

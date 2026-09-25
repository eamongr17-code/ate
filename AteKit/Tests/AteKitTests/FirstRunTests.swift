import Foundation
import Testing

@testable import AteKit

/// Every new account is sent through `Handle`, and nobody else is.
@Suite("First run — who owes a handle")
struct FirstRunTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Apple's first authorization is a new account, whatever the clock says")
    func firstAuthorization() {
        #expect(FirstRun.isNewAccount(isFirstAuthorization: true, createdAt: nil, now: now))
        #expect(FirstRun.isNewAccount(
            isFirstAuthorization: true, createdAt: now.addingTimeInterval(-86_400 * 30), now: now
        ))
    }

    @Test("an account made minutes ago is new even when Apple stayed quiet — the second sign-up")
    func freshAccountWithoutApplesName() {
        #expect(FirstRun.isNewAccount(isFirstAuthorization: false, createdAt: now.addingTimeInterval(-30), now: now))
        #expect(FirstRun.isNewAccount(
            isFirstAuthorization: false, createdAt: now.addingTimeInterval(-FirstRun.newAccountWindow + 1), now: now
        ))
    }

    @Test("a returning person is not sent back to Handle")
    func returning() {
        #expect(FirstRun.isNewAccount(
            isFirstAuthorization: false, createdAt: now.addingTimeInterval(-86_400), now: now
        ) == false)
        #expect(FirstRun.isNewAccount(isFirstAuthorization: false, createdAt: nil, now: now) == false)
    }

    @Test("the trigger's placeholders are recognised, in every shape 0032 can mint")
    func placeholders() {
        #expect(HandleName.isPlaceholder("ate1a2b3c4d"))
        #expect(HandleName.isPlaceholder("ate1a2b3c4d2"), "the collision counter")
        #expect(HandleName.isPlaceholder("ate" + String(repeating: "f", count: 27)), "the whole-id fallback")
    }

    @Test("a chosen handle is never mistaken for a placeholder")
    func chosenHandles() {
        #expect(HandleName.isPlaceholder("eamon") == false)
        #expect(HandleName.isPlaceholder("ate") == false)
        #expect(HandleName.isPlaceholder("atepizza") == false)
        #expect(HandleName.isPlaceholder("ate1a2b3c") == false, "seven hex is not the trigger's")
        #expect(HandleName.isPlaceholder("ate_1a2b3c4d") == false)
    }
}

/// `my_blocks` and `delete_account`, decoded from the wire shapes the contract prints.
@Suite("Account — wire shapes")
struct AccountWireTests {

    @Test("a my_blocks row decodes into a named, pageable person")
    func blockedPerson() throws {
        let json = Data("""
        [{"blocked_id":"0b6f8a6e-6a39-4c4c-9a53-0e1b2f3c4d5e","username":"alice","name":"Alice",
          "avatar_url":"https://example.invalid/a.jpg","city":"Melbourne",
          "created_at":"2026-09-25T10:11:12.123456+00:00"}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([BlockedPerson].self, from: json)
        let row = try #require(rows.first)
        #expect(row.title == "@alice")
        #expect(row.name == "Alice")
        #expect(row.avatarURL?.absoluteString == "https://example.invalid/a.jpg")
        #expect(row.pageCursor.id == row.id)
    }

    @Test("an account that no longer exists comes back unnamed, and is still a row")
    func goneAccount() throws {
        let json = Data("""
        [{"blocked_id":"0b6f8a6e-6a39-4c4c-9a53-0e1b2f3c4d5e","username":null,"name":null,
          "avatar_url":null,"city":null,"created_at":"2026-09-25T10:11:12+00:00"}]
        """.utf8)
        let row = try #require(try PostgRESTDate.decoder.decode([BlockedPerson].self, from: json).first)
        #expect(row.title == "Blocked account")
        #expect(row.avatarURL == nil)
    }

    @Test("delete_account's answer: ok, and whether the login went with it")
    func deletion() throws {
        let whole = try JSONDecoder().decode(
            AccountDeletion.self, from: Data(#"{"ok":true,"auth_user_deleted":true}"#.utf8)
        )
        #expect(whole.isComplete)
        let half = try JSONDecoder().decode(
            AccountDeletion.self, from: Data(#"{"ok":true,"auth_user_deleted":false}"#.utf8)
        )
        #expect(half.ok)
        #expect(half.isComplete == false)
    }
}

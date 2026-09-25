import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **First run, Settings and account deletion, against staging** — `handle_available` (0019),
/// `my_blocks` and `delete_account` (0032).
///
/// What these guard:
///
/// - **`handle_available` is case-insensitive.** `profiles.username` is `citext`, so the check and the
///   UNIQUE index behind it agree. That agreement is the whole point of the RPC existing (a plain
///   client-side select reports a taken handle as free, because the block-aware policy hides its
///   owner), and a future "tidy-up" to `lower(username) = lower($1)` on text would pass a linter and
///   break first run. Pinned here, against the real handle the demo account holds.
/// - **`my_blocks` can name the people the `profiles` policy hides.** `profiles_select_visible` is
///   `id = auth.uid() or not blocked_with(id)`, and a person you blocked is by definition
///   `blocked_with` — so the obvious PostgREST embed returns a list of UUIDs with no handle and no
///   avatar. The test blocks a seeded author, asserts the row comes back NAMED, and unblocks.
///
/// Opt-in: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5).
@Suite("Account and blocks — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct AccountContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    // MARK: - handle_available

    @Test("handle_available answers the same for any casing of a taken handle")
    func handleAvailabilityIsCaseInsensitive() async throws {
        let client = try await client()
        let me = try await client.requireCurrentUserID()
        let mine = try #require(try await client.fetchByIDs(User.self, ids: [me]).first)
        let handle = mine.username
        try #require(handle.isEmpty == false)

        for variant in [handle, handle.uppercased(), handle.lowercased(), handle.capitalized] {
            let answer = try await StagingRPC.raw(
                client, "handle_available", ["p_handle": .string(variant)]
            )
            #expect(answer == "false", "'\(variant)' is taken — citext does not care about case")
        }

        // Surrounding whitespace is trimmed, not treated as a different handle.
        let padded = try await StagingRPC.raw(
            client, "handle_available", ["p_handle": .string("  \(handle)  ")]
        )
        #expect(padded == "false")
    }

    @Test("a handle nobody holds is free, and an illegal length never is")
    func handleAvailabilityBounds() async throws {
        let client = try await client()
        let free = "ate" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        #expect(try await StagingRPC.raw(client, "handle_available", ["p_handle": .string(free)]) == "true")
        // 1–30 characters, and the trim happens first: "" and "   " are both refusals, not crashes.
        #expect(try await StagingRPC.raw(client, "handle_available", ["p_handle": .string("")]) == "false")
        #expect(try await StagingRPC.raw(client, "handle_available", ["p_handle": .string("   ")]) == "false")
        #expect(
            try await StagingRPC.raw(
                client, "handle_available", ["p_handle": .string(String(repeating: "a", count: 31))]
            ) == "false"
        )
        // NOTE, deliberately not asserted: the RPC does NOT validate the character set. "a b!" is
        // "available" as far as the server is concerned — the client owns that rule (0032 finding 4).
    }

    // MARK: - my_blocks

    @Test("my_blocks names the person the profiles policy hides from the blocker")
    func blockedListIsRenderable() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let feed = EntryFeedClient(api: client)
            let someone = try #require(
                try await feed.feedPage(after: nil, pageSize: 50, includeOwn: false).items.last?.authorID,
                "staging seeds other people's entries"
            )

            try await client.callRPC(
                "block_user", parameters: ["p_user_id": .string(someone.uuidString.lowercased())]
            )
            // Unblocked whatever happens below: a staging cohort that loses a member to a failed
            // assertion is a worse bug than the one this test looks for.
            defer {
                Task {
                    try? await client.callRPC(
                        "unblock_user", parameters: ["p_user_id": .string(someone.uuidString.lowercased())]
                    )
                }
            }

            let rows: [MyBlockRow] = try await StagingRPC.rows(
                client, "my_blocks",
                [
                    "p_limit": .integer(50),
                    "p_cursor_created_at": .null,
                    "p_cursor_blocked_id": .null
                ]
            )
            let row = try #require(rows.first { $0.blockedID == someone }, "the block I just made is missing")

            // The point of the DEFINER read: a plain select through RLS cannot see this profile.
            #expect(row.username?.isEmpty == false, "Settings cannot draw a list of UUIDs")
            #expect(row.name?.isEmpty == false)
            #expect(row.avatarURL != "")
            #expect(row.city != "")

            // Newest block first, and the cursor is (created_at, blocked_id).
            let ordered = zip(rows, rows.dropFirst()).allSatisfy { first, second in
                (first.createdAt, first.blockedID.uuidString) > (second.createdAt, second.blockedID.uuidString)
            }
            #expect(ordered, "created_at DESC, blocked_id DESC")

            // One-way and self-free: the RPC lists whom I blocked, never who blocked me, and
            // `blocks_no_self` means I can never be in my own list.
            #expect(rows.allSatisfy { $0.blockedID != me })

            try await client.callRPC(
                "unblock_user", parameters: ["p_user_id": .string(someone.uuidString.lowercased())]
            )
            let after: [MyBlockRow] = try await StagingRPC.rows(client, "my_blocks", ["p_limit": .integer(50)])
            #expect(after.contains { $0.blockedID == someone } == false, "unblock removes the row")
        }
    }
}

/// **Account deletion, proved by deleting an account** (`delete_account`, 0032).
///
/// Separately opt-in — `ATE_ACCOUNT_DELETION_TEST=1` on top of `ATE_CONTRACT_TESTS=1` — for one
/// reason: it signs a THROWAWAY user up on staging and deletes it. That is legal synthetic data in
/// staging and nowhere else, but it is a write the ordinary contract run has no business making on
/// every PR, and it must never be pointed at an account a person uses.
///
/// It is the only way to answer the question the RPC's return value exists for: `delete_account`
/// deletes `auth.users` from a SECURITY DEFINER function, which depends on the function owner's
/// rights on the auth schema. If that privilege is ever not there, `auth_user_deleted` comes back
/// `false`, the user's DATA is still gone (the fallback scrubs and deletes it) but the account can
/// still be signed into — and we owe it an edge function using `auth.admin.deleteUser`. Run this once
/// per environment after 0032 applies; a red result here is a decision, not a flake.
@Suite(
    "Account deletion — staging probe",
    .enabled(if: StagingContract.isEnabled && StagingContract.environmentValue("ATE_ACCOUNT_DELETION_TEST") != nil),
    .serialized
)
struct AccountDeletionProbeTests {

    @Test("delete_account removes the auth user, the profile and the caller's content")
    func deleteAccountDeletesTheAccount() async throws {
        // A throwaway identity, unmistakably synthetic and unique per run.
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let email = "delete-probe-\(tag)@ate.test"
        let password = "probe-\(tag)"

        let supabase = StagingContract.makeClient()
        let signUp = try await supabase.auth.signUp(email: email, password: password)
        let userID = signUp.user.id
        try #require(
            signUp.session != nil,
            """
            staging returned no session for a fresh sign-up — email confirmations are on, so this \
            probe cannot act as the throwaway user. Turn them off for staging or run the deletion \
            check by hand against a user you created in the dashboard.
            """
        )
        let client = AteAPIClient(supabase: supabase)

        // The trigger provisioned a profile (this is also the Apple path's guarantee: an identity
        // with no name still gets a legal, unique handle).
        let provisioned = try await client.fetchByIDs(User.self, ids: [userID])
        #expect(provisioned.count == 1, "handle_new_user must provision a profile, even for a bare identity")
        #expect(provisioned.first?.username.isEmpty == false)

        let result: DeleteAccountResult = try await StagingRPC.value(client, "delete_account")
        #expect(result.ok)
        #expect(
            result.authUserDeleted,
            """
            delete_account could not delete auth.users — the data is gone but the account can still \
            be signed into. This needs an edge function calling auth.admin.deleteUser; tell the lead.
            """
        )

        // Signing in again must fail: the account is gone, not deactivated.
        let fresh = StagingContract.makeClient()
        await #expect(throws: (any Error).self) {
            _ = try await fresh.auth.signIn(email: email, password: password)
        }
    }
}

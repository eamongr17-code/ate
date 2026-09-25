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

/// **Throwaway accounts on staging: sign-up, deactivation, deletion** (0032, fixed in 0035).
///
/// Separately opt-in — `ATE_ACCOUNT_DELETION_TEST=1` on top of `ATE_CONTRACT_TESTS=1` — because each
/// test signs a THROWAWAY user up on staging (legal synthetic data there, nowhere else) and deletes it
/// before it finishes, pass or fail. Never pointed at an account a person uses. Needs staging email
/// confirmations off, so a fresh sign-up returns a session.
///
/// - **Sign-up always yields a profile** (`handle_new_user`): the probe asks for a handle that is
///   already taken (the demo account's), and must still get a profile, under a different handle.
/// - **Deletion is real or it is an error** (`delete_account`): `{ok: true, auth_user_deleted:
///   true}`, then the password no longer signs in. The failure branch (auth delete refused) needs the
///   service role to provoke and is not driven here; 0035 makes it raise, so a regression back to a
///   silent `ok` would have to change the function this suite calls.
/// - **A deactivated profile disappears** (0035): before `deactivate_account` the demo viewer and a
///   signed-out browser both see the probe's profile and entry; after it, neither does, and search
///   does not find the handle.
@Suite(
    "Account lifecycle — staging probe",
    .enabled(if: StagingContract.isEnabled && StagingContract.environmentValue("ATE_ACCOUNT_DELETION_TEST") != nil),
    .serialized
)
struct AccountDeletionProbeTests {
    struct Probe {
        let client: AteAPIClient
        let userID: UUID
        let email: String
        let password: String
    }

    /// A throwaway identity, unmistakably synthetic and unique per run. `data` rides into
    /// `raw_user_meta_data`, which is what `handle_new_user` derives the handle from.
    func signUpProbe(requestingHandle handle: String? = nil) async throws -> Probe {
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let email = "delete-probe-\(tag)@ate.test"
        let password = "probe-\(tag)"
        let supabase = StagingContract.makeClient()
        let signUp = try await supabase.auth.signUp(
            email: email, password: password, data: handle.map { ["username": .string($0)] }
        )
        try #require(
            signUp.session != nil,
            "staging returned no session for a fresh sign-up — email confirmations are on; turn them off for staging"
        )
        return Probe(client: AteAPIClient(supabase: supabase), userID: signUp.user.id, email: email, password: password)
    }

    func deleteAccount(_ probe: Probe) async throws -> DeleteAccountResult {
        try await StagingRPC.value(probe.client, "delete_account")
    }

    /// Runs `body`, then deletes the probe whatever happened, so a red test never strands a user.
    func withProbe(
        requestingHandle handle: String? = nil,
        _ body: (Probe) async throws -> Void
    ) async throws {
        let probe = try await signUpProbe(requestingHandle: handle)
        do {
            try await body(probe)
        } catch {
            _ = try? await deleteAccount(probe)
            throw error
        }
        _ = try? await deleteAccount(probe)
    }

    @Test("a taken handle still yields a profile; delete_account deletes the account or raises")
    func signUpThenDelete() async throws {
        let demo = try await StagingContract.Backend.shared.client()
        let demoID = try await demo.requireCurrentUserID()
        let taken = try #require(try await demo.fetchByIDs(User.self, ids: [demoID]).first?.username)

        let probe = try await signUpProbe(requestingHandle: taken)
        let provisioned = try await probe.client.fetchByIDs(User.self, ids: [probe.userID])
        #expect(provisioned.count == 1, "handle_new_user must ALWAYS leave a profile (0035)")
        #expect(provisioned.first.map { $0.username.lowercased() != taken.lowercased() } == true)

        let result = try await deleteAccount(probe)
        #expect(result.ok && result.authUserDeleted, "0035: success is total, anything else raises")

        let fresh = StagingContract.makeClient()
        await #expect(throws: (any Error).self, "the account is gone, not deactivated") {
            _ = try await fresh.auth.signIn(email: probe.email, password: probe.password)
        }
    }

    @Test("a deactivated profile and its entries vanish for signed-in and signed-out readers")
    func deactivatedProfileIsHidden() async throws {
        let demo = try await StagingContract.Backend.shared.client()
        let anon = AteAPIClient(supabase: StagingContract.makeClient())

        try await withProbe { probe in
            let handle = try #require(try await probe.client.fetchByIDs(User.self, ids: [probe.userID]).first?.username)
            try await probe.client.supabase.from("entries").insert([
                "id": UUID().uuidString.lowercased(),
                "author_id": probe.userID.uuidString.lowercased(),
                "body": "deactivation probe"
            ]).execute()

            func profile(_ reader: AteAPIClient) async throws -> [ProfileSummary] {
                try await StagingRPC.rows(reader, "profile_summary", ["p_user_id": StagingRPC.id(probe.userID)])
            }
            func entries(_ reader: AteAPIClient) async throws -> [EntryCard] {
                try await StagingRPC.rows(reader, "get_entries_by_author", [
                    "p_author_id": StagingRPC.id(probe.userID),
                    "p_cursor_created_at": .null, "p_cursor_id": .null, "p_page_size": .integer(10)
                ])
            }
            func found(_ reader: AteAPIClient) async throws -> Bool {
                let rows: [SearchPersonRow] = try await StagingRPC.rows(
                    reader, "search_people", ["p_query": .string(handle), "p_limit": .integer(50)]
                )
                return rows.contains { $0.userID == probe.userID }
            }

            // Visible first — otherwise "hidden" below would prove nothing.
            for reader in [demo, anon] {
                #expect(try await profile(reader).count == 1)
                #expect(try await entries(reader).count == 1)
            }
            #expect(try await found(demo))

            try await probe.client.callRPC("deactivate_account")

            for reader in [demo, anon] {
                #expect(try await profile(reader).isEmpty, "a deactivated profile has no header")
                #expect(try await entries(reader).isEmpty, "a deactivated profile's entries are gone")
            }
            #expect(try await found(demo) == false, "search must not find a deactivated handle")
            // The owner still sees themselves (and can still delete the account).
            #expect(try await profile(probe.client).count == 1)
        }
    }
}

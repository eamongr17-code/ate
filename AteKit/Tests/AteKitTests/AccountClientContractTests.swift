import CoreGraphics
import Foundation
import ImageIO
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The app's own account client, against staging** — `AccountClient` exactly as Settings and
/// `Handle` call it: `handle_available` (0019), the `profiles.username` write, `my_blocks` +
/// `unblock_user` (0019/0032), and `delete_account` with the storage purge in front of it (0032).
///
/// The backend's own suite (`AccountContractTests`) proves the RPCs; this one proves the client's
/// request shapes and decoding against them, so a renamed parameter or a changed column fails here
/// rather than on the Settings page.
///
/// Opt-in: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5).
@Suite("Account client — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct AccountClientContractTests {

    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    func account() async throws -> AccountClient {
        AccountClient(api: try await client())
    }

    // MARK: - handle_available

    @Test("handle_available through the client: taken in any casing, free when nobody holds it")
    func availability() async throws {
        let account = try await account()
        let mine = try await account.account().username
        #expect(mine.isEmpty == false)
        #expect(try await account.isHandleAvailable(mine) == false, "my own handle read as free")
        #expect(try await account.isHandleAvailable(mine.uppercased()) == false, "citext compared by case")

        let free = "ct" + UUID().uuidString.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(14)
        #expect(HandleName.isWellFormed(free))
        #expect(try await account.isHandleAvailable(free))
    }

    @Test("whatever the field refuses to produce, the server refuses too")
    func theFieldAndTheColumnAgree() async throws {
        let account = try await account()
        // The app never sends what was typed — it sends `HandleName.sanitise` of it. So the pairing
        // that keeps `Handle`'s single green check honest with no error copy is: every sanitised
        // value the field calls malformed is one the server refuses as well.
        for typed in ["", "@", "   ", "!!!", "@@@"] {
            let sanitised = HandleName.sanitise(typed)
            #expect(HandleName.isWellFormed(sanitised) == false)
            #expect(try await account.isHandleAvailable(sanitised) == false)
        }
        // …and the 30-character cap means a long paste never reaches the column at a length it
        // would refuse.
        let capped = HandleName.sanitise(String(repeating: "z", count: 31))
        #expect(capped.count == HandleName.maximumLength)
        #expect(try await account.isHandleAvailable(capped), "30 z's are nobody's, and legal")
    }

    // MARK: - profiles

    @Test("setHandle and setName write through profiles_update_self")
    func writesTheProfile() async throws {
        // Written back to their own values: proves the columns, the RLS policy and the request shape
        // without renaming the account every other suite signs in as.
        try await StagingExclusive.shared.run {
            let account = try await account()
            let before = try await account.account()
            try await account.setHandle(before.username)
            let after = try await account.account()
            #expect(after.username == before.username)
            #expect(after.id == before.id)

            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let name = try #require(try await client.fetchByIDs(User.self, ids: [me]).first?.name)
            try await account.setName(name)
            #expect(try await client.fetchByIDs(User.self, ids: [me]).first?.name == name)
        }
    }

    // MARK: - my_blocks + unblock_user

    @Test("Blocked people: my_blocks names the person, pages by keyset, and unblock empties it")
    func blockedListAndUnblock() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let account = AccountClient(api: client)
            let profiles = ProfileClient(api: client)

            let feed = try await EntryFeedClient(api: client)
                .feedPage(after: nil, pageSize: 50, includeOwn: false)
            let authors = Array(Set(feed.items.map(\.authorID))).prefix(2)
            try #require(authors.count == 2, "staging seeds at least two other people")
            for author in authors { try await profiles.block(userID: author) }
            defer {
                Task {
                    for author in authors { try? await AccountClient(api: client).unblock(userID: author) }
                }
            }

            // One row per page, so the cursor is exercised: the second page must be the other one.
            let first = try await account.blockedPeople(after: nil, pageSize: 1)
            let firstRow = try #require(first.items.first)
            let second = try await account.blockedPeople(after: first.nextCursor, pageSize: 1)
            let secondRow = try #require(second.items.first, "the cursor skipped the second block")
            #expect(firstRow.id != secondRow.id)
            #expect(firstRow.blockedAt >= secondRow.blockedAt, "newest block first")
            #expect(Set([firstRow.id, secondRow.id]) == Set(authors), "the two newest blocks are these two")

            // The point of the definer read: the row is NAMED, where an embed through RLS was not.
            let named = try await account.blockedPeople(after: nil, pageSize: 50).items
                .filter { authors.contains($0.id) }
            #expect(named.count == 2)
            #expect(named.allSatisfy { $0.username?.isEmpty == false }, "Settings cannot draw a list of UUIDs")
            #expect(named.allSatisfy { $0.title.hasPrefix("@") })

            for author in authors { try await account.unblock(userID: author) }
            let after = try await account.blockedPeople(after: nil, pageSize: 50).items
            #expect(after.contains { authors.contains($0.id) } == false, "unblock_user left a row behind")
        }
    }

    // MARK: - delete_account

    /// A throwaway staging user, signed up, given an avatar, and deleted through the client — the
    /// whole Delete account path, storage purge first. Separately opt-in with the backend's probe
    /// (`ATE_ACCOUNT_DELETION_TEST=1`), because it writes a user to staging on every run, and it needs
    /// a sign-up to return a session: staging currently has `mailer_autoconfirm: false`, so until
    /// email confirmation is off for staging this test stops at its first `#require`.
    @Test(
        "Delete account: the photo is purged, delete_account takes the login, and nothing signs back in",
        .enabled(if: StagingContract.environmentValue("ATE_ACCOUNT_DELETION_TEST") != nil)
    )
    func deletesAThrowawayAccount() async throws {
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        // Named so a service-role sweep can find any that a failed run leaves behind.
        let email = "ate-contract-\(tag)@ate.test"
        let password = "Contract-\(tag)!"
        let supabase = StagingContract.makeClient()
        let signUp = try await supabase.auth.signUp(email: email, password: password)
        try #require(signUp.session != nil, "staging sent a confirmation email instead of a session")
        let client = AteAPIClient(supabase: supabase)
        let account = AccountClient(api: client)

        // First run, as the app does it: the placeholder handle is replaced with a chosen one.
        let chosen = "ct\(tag)"
        #expect(try await account.isHandleAvailable(chosen))
        try await account.setHandle(chosen)
        #expect(try await account.account().username == chosen)

        // Something in the avatars bucket for the purge to find.
        let avatar = try await account.setAvatar(AvatarUpload(data: Self.onePixelJPEG))

        let deletion = try await account.deleteAccount()
        #expect(deletion.ok)
        #expect(deletion.authUserDeleted, "delete_account could not delete auth.users — tell the lead")
        try? await account.signOut()

        // The bytes are gone, not just the row: the bucket is public, so the URL answers for itself.
        var request = URLRequest(url: avatar)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode != 200, "the avatar outlived its account")

        // …and the handle went back into the pool with the profile.
        let viewer = try await self.account()
        #expect(try await viewer.isHandleAvailable(chosen), "a deleted account still holds its handle")

        let fresh = StagingContract.makeClient()
        await #expect(throws: (any Error).self) {
            _ = try await fresh.auth.signIn(email: email, password: password)
        }
    }

    /// A real 1×1 JPEG, so the bucket's content-type check is exercised on a real image.
    static var onePixelJPEG: Data {
        let data = NSMutableData()
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

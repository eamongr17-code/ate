import Foundation
import Testing
@testable import AteKit

@Suite("BuildStamp")
struct BuildStampTests {
    @Test("summary names the environment and the Supabase project")
    func summaryIncludesProject() {
        let stamp = BuildStamp(environment: .staging)
        #expect(stamp.summary(supabaseHost: "cvoitgoaosofkougmarn.supabase.co") == "Staging · Supabase cvoitgoaosofkougmarn")
    }

    @Test("summary falls back to the environment name when there is no host")
    func summaryWithoutHost() {
        #expect(BuildStamp(environment: .production).summary(supabaseHost: nil) == "Production")
    }
}

@testable import AteKit
import Foundation
import Testing

@Suite("Legal documents — the privacy policy and terms Settings shows")
struct LegalDocumentTests {
    /// `legal/` at the repo root, from this file's own path.
    private static func repoFile(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AteKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AteKit
            .deletingLastPathComponent() // repo
        return try String(contentsOf: root.appending(path: "legal/\(name)"), encoding: .utf8)
    }

    @Test("the app's words are legal/*.md word for word")
    func matchesRepo() throws {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(trim(LegalDocument.privacyMarkdown) == trim(try Self.repoFile("privacy.md")))
        #expect(trim(LegalDocument.termsMarkdown) == trim(try Self.repoFile("terms.md")))
    }

    @Test("headings, paragraphs and points, in order; the title without the app's name")
    func parses() {
        let document = LegalDocument(markdown: "# Ate — Terms\n\n_Updated._\n\n## Using Ate\n- Be 13.\n- Be kind.\n")
        #expect(document.title == "Terms")
        #expect(document.blocks == [
            .paragraph("_Updated._"), .heading("Using Ate"), .bullet("Be 13."), .bullet("Be kind.")
        ])
        #expect(LegalDocument.privacy.title == "Privacy Policy")
        #expect(LegalDocument.terms.title == "Terms of Use")
    }
}

import Foundation

/// **The privacy policy and the terms, in the app** — Settings' Privacy and Terms rows open these
/// rather than a web page (Eamon, 18 Oct). The words are `legal/privacy.md` and `legal/terms.md`
/// verbatim (TestFlight's privacy link points at the first); `LegalDocumentTests` fails the day the
/// two drift, so edit the file and paste it here in the same change.
public struct LegalDocument: Sendable, Equatable {
    /// One piece of the page, top to bottom.
    public enum Block: Sendable, Equatable {
        /// `## What we collect`
        case heading(String)
        /// A paragraph; `**bold**` and `_italic_` are left in for the page to draw.
        case paragraph(String)
        /// `- A point.`
        case bullet(String)
    }

    /// `# Ate — Privacy Policy`: the page's own name, without the "Ate — ".
    public let title: String
    public let blocks: [Block]
    /// The Markdown it was read from.
    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
        var title = ""
        var blocks: [Block] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                let name = String(line.dropFirst(2))
                title = name.components(separatedBy: " — ").last ?? name
            } else if line.hasPrefix("- ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.isEmpty == false {
                blocks.append(.paragraph(line))
            }
        }
        self.title = title
        self.blocks = blocks
    }

    public static let privacy = LegalDocument(markdown: privacyMarkdown)
    public static let terms = LegalDocument(markdown: termsMarkdown)

    // swiftlint:disable line_length
    static let privacyMarkdown = #"""
# Ate — Privacy Policy

_Last updated: 18 October 2026. Contact: eamongr17@gmail.com._

Ate is a journal for the dishes you eat. This policy says what we collect and why.

## What we collect
- **Your account.** When you sign in with Apple we receive an identifier and, if you choose to share it, your name and email. You pick a handle.
- **What you write.** Your entries: dishes, scores, words, photos, the place, and any lists or saves. Entries you publish are visible to other Ate users and to anyone you send a link to.
- **Location, only when you allow it.** Used to show places near you and what people are eating in your city. We do not track your location in the background.
- **Photos, only the ones you pick.** Ate can look at recent photos to suggest meals you haven't written up; nothing leaves your phone unless you add it to an entry.
- **Links you share into Ate.** When you share a TikTok, Instagram or web link to Ate, we read the public page to suggest the dish and place.
- **Usage and crashes.** Anonymous usage counts (TelemetryDeck) and crash reports (Sentry), so we can fix and improve the app. No advertising identifiers.

## Who processes it
- **Supabase** stores your account and entries.
- **Anthropic (Claude)** reads entry text, the photos on an entry and shared links to name dishes, match photos to dishes and suggest places. It is not used to train models.
- **Google Places** looks up restaurants when you search.
- **TelemetryDeck** and **Sentry**, as above.

We do not sell your data or show ads.

## Your choices
- Delete any entry at any time.
- Delete your account in Settings; your entries, photos and profile are removed, and Ate's access to your Apple ID is revoked.
- Turn off location or photo access in iOS Settings.

## Children
Ate is not for children under 13.

## Changes
We'll update this page and the date above if anything changes.
"""#

    static let termsMarkdown = #"""
# Ate — Terms of Use

_Last updated: 18 October 2026. Contact: eamongr17@gmail.com._

These terms apply when you use Ate. By using the app you agree to them.

## Using Ate
- You must be at least 13.
- Keep your Apple sign-in secure; you're responsible for what's posted from your account.
- Ate is in beta. Things may change, break or be removed.

## Your content
- What you write and the photos you add stay yours.
- Entries you publish can be seen by other Ate users and anyone you send a link to. You let Ate store, show and share them for that purpose, and nothing else.
- Only post what you have the right to post.

## Be decent
- No abuse, harassment, hate, spam, or anything illegal.
- Reviews should be your honest experience. No fake reviews, and no reviews of your own business.
- We may remove content or suspend accounts that break these rules. You can block anyone, any time.

## Ending
- Delete your account in Settings whenever you like; your entries, photos and profile go with it.

## No guarantees
Ate is provided as is. Scores and reviews are people's opinions, not ours. To the extent the law allows, we aren't liable for losses from using the app. Nothing here limits rights you have under Australian Consumer Law.

## Changes
We'll update these terms and the date above if anything changes. These terms are governed by the laws of Victoria, Australia.
"""#
    // swiftlint:enable line_length
}

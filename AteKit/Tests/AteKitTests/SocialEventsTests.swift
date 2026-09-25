import Foundation
import Testing
@testable import AteKit

/// The funnel's names and parameters, pinned. A dashboard cannot tell you an event was renamed —
/// it just goes quiet — so the names live in one enum and are asserted here.
@Suite("Feed and save events")
struct SocialEventsTests {

    @Test("The feed's two events")
    func feed() {
        #expect(SocialEvents.feedViewed().name == "feed_viewed")
        let page = SocialEvents.feedPageLoaded(page: 2, itemCount: 20)
        #expect(page.name == "feed_page_loaded")
        #expect(page.parameters == ["page": "2", "items": "20"])
    }

    @Test("Page numbers are 1-based and counts never go negative")
    func clamping() {
        let page = SocialEvents.feedPageLoaded(page: 0, itemCount: -3)
        #expect(page.parameters == ["page": "1", "items": "0"])
    }

    /// The source is the whole point of this event: a save in the feed is somebody deciding where to
    /// eat next; a tap in the Saved list is only ever an unsave.
    @Test("A save carries where it was made and which way it went")
    func saves() {
        let on = SocialEvents.saveToggled(source: .feed, isSaved: true)
        #expect(on.name == "save_toggled")
        #expect(on.parameters == ["source": "feed", "state": "on"])
        let off = SocialEvents.saveToggled(source: .savedList, isSaved: false)
        #expect(off.parameters == ["source": "saved_list", "state": "off"])
        #expect(SaveSource.allCases.map(\.rawValue)
            == ["feed", "entry", "saved_list", "profile", "place", "dish", "search"])
        // The dish page's own bookmark and a place page's: the same event, so "how often people
        // save" stays one number however many surfaces grow one.
        #expect(SocialEvents.saveToggled(source: .dish, isSaved: true).parameters
            == ["source": "dish", "state": "on"])
        #expect(SocialEvents.saveToggled(source: .place, isSaved: true).parameters
            == ["source": "place", "state": "on"])
    }

    @Test("Profiles and moderation")
    func profilesAndModeration() {
        #expect(SocialEvents.profileViewed(isMe: false).parameters == ["is_me": "false"])
        #expect(SocialEvents.profileViewed(isMe: true).name == "profile_viewed")
        #expect(SocialEvents.userBlocked().name == "user_blocked")
        #expect(SocialEvents.entryReported().name == "entry_reported")
        #expect(SocialEvents.profileReported().name == "profile_reported")
    }
}

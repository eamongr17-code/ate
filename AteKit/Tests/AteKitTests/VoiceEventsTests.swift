import Foundation
import Testing
@testable import AteKit

/// The mic key's and the camera key's three-and-one events, pinned like the rest of the funnel: a
/// renamed event is a dashboard series that silently goes to zero.
@Suite("Voice and camera events")
struct VoiceEventsTests {

    @Test("the names are the composer's own vocabulary")
    func names() {
        #expect(EntryEvents.voiceStarted().name == "entry_voice_started")
        #expect(EntryEvents.voiceCommitted(wordCount: 0, tokenCount: 0).name == "entry_voice_committed")
        #expect(EntryEvents.voiceDenied(reason: .microphone).name == "entry_voice_denied")
        #expect(EntryEvents.cameraCaptured(photoCount: 1).name == "entry_camera_captured")
    }

    @Test("a committed dictation carries what was said and what it minted")
    func committed() {
        let event = EntryEvents.voiceCommitted(wordCount: 24, tokenCount: 2)
        #expect(event.parameters["word_count"] == "24")
        #expect(event.parameters["token_count"] == "2")
    }

    @Test("counts can never go out negative")
    func clampsCounts() {
        let event = EntryEvents.voiceCommitted(wordCount: -3, tokenCount: -1)
        #expect(event.parameters["word_count"] == "0")
        #expect(event.parameters["token_count"] == "0")
        #expect(EntryEvents.cameraCaptured(photoCount: -2).parameters["photo_count"] == "0")
    }

    @Test("a refusal says which of the three it was")
    func deniedReasons() {
        #expect(VoiceDenialReason.allCases.map(\.rawValue).sorted()
            == ["microphone", "speech", "unavailable"])
        for reason in VoiceDenialReason.allCases {
            #expect(EntryEvents.voiceDenied(reason: reason).parameters["reason"] == reason.rawValue)
        }
    }

    @Test("a score said out loud is the same event a typed one sends, with its own source")
    func dictatedScoreUsesTheExistingEvent() {
        let event = EntryEvents.scoreTokenCreated(source: .dictation)
        #expect(event.name == "entry_score_token_created")
        #expect(event.parameters["source"] == "dictation")
    }
}

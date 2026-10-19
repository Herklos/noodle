import Foundation
@testable import NoodleMobile
import Testing

@MainActor @Suite struct VoiceTranscriptTests {
    // Transcripts have no word timings, so a fraction of the recording is the same fraction of the text.
    @Test func sentencesFollowTheRecordingByProportion() throws {
        let text = try #require(VoiceTranscriptText("One two. Three four five six?  Seven!"))
        #expect(text.sentences.map { String(text.text[$0]) } == ["One two.", "Three four five six?", "Seven!"])
        #expect(text.starts == [0, 9, 31])
        #expect(text.count == 37)
        #expect([0, 0.2, 0.25, 0.8, 0.9, 1].map(text.sentence(at:)) == [0, 0, 1, 1, 2, 2])
        #expect([-1, 2, .nan, .infinity].map(text.sentence(at:)) == [0, 2, 0, 0])
        #expect(text.fraction(of: 1) == 9.0 / 37)
        #expect(text.fraction(of: 7) == 0)
        for index in text.sentences.indices {
            #expect(text.sentence(at: text.fraction(of: index)) == index, "Tapping a sentence marks that sentence")
        }
    }

    @Test func aTranscriptWithoutSentencesIsOneAndAMissingOneIsNone() throws {
        let words = try #require(VoiceTranscriptText("  just some words "))
        #expect(words.sentences.map { String(words.text[$0]) } == ["just some words"])
        #expect(words.sentence(at: 0.7) == 0)
        #expect(VoiceTranscriptText(nil) == nil)
        #expect(VoiceTranscriptText(" \n ") == nil)
        #expect(VoiceTranscriptText.missing == "No transcript was made for this voice message.")
    }

    @Test func sentenceLinksNameTheirSentence() throws {
        #expect(VoiceTranscriptBody.sentence(in: try #require(URL(string: "noodle-transcript-sentence:12"))) == 12)
        #expect(VoiceTranscriptBody.sentence(in: try #require(URL(string: "https://example.com/12"))) == nil)
    }
}

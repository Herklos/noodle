import AVFAudio
@testable import NoodleMobile
import Testing

/// The call screen's speaker button moves the call between the phone's own earpiece and
/// loudspeaker; other outputs, such as AirPods, are no choice between the two.
struct CallRouteTests {
    @Test func theCallScreenCanChooseTheLoudspeakerOrTheEarpiece() {
        #expect(EngineCallAudio.speakerChosen(by: [.builtInSpeaker]) == true)
        #expect(EngineCallAudio.speakerChosen(by: [.builtInReceiver]) == false)
        #expect(EngineCallAudio.speakerChosen(by: [.bluetoothA2DP]) == nil)
        #expect(EngineCallAudio.speakerChosen(by: [.headphones]) == nil)
        #expect(EngineCallAudio.speakerChosen(by: []) == nil)
    }
}

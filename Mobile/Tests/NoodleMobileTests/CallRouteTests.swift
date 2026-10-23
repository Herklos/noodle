import AVFAudio
import CallKit
@testable import NoodleMobile
import Testing

/// The call screen's speaker button moves the call between the phone's own earpiece and
/// loudspeaker. Any other output, such as a car or AirPods, means the call is off the loudspeaker.
struct CallRouteTests {
    @Test func theCallScreenCanChooseTheLoudspeakerOrTheEarpiece() {
        #expect(EngineCallAudio.speakerChosen(by: [.builtInSpeaker]) == true)
        #expect(EngineCallAudio.speakerChosen(by: [.builtInReceiver]) == false)
        #expect(EngineCallAudio.speakerChosen(by: []) == nil)
    }

    /// A call taken in the car, or moved to it, plays through the car and never goes back to the phone's
    /// loudspeaker: connecting the car ends the loudspeaker override, and the call follows the car.
    /// A real car (or the CarPlay Simulator) is still needed to hear the route iOS picks.
    @Test func aCallOnTheLoudspeakerMovesToTheCarWhenItConnects() {
        for external: AVAudioSession.Port in [.carAudio, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .usbAudio] {
            #expect(EngineCallAudio.speakerChosen(by: [external]) == false, "\(external.rawValue) is no loudspeaker")
        }
    }

    @Test func aRouteChangeToTheCarTurnsTheLoudspeakerOffAndKeepsTheCallThere() {
        // On the loudspeaker when the car connects: the speaker goes off, so nothing routes back to the phone.
        #expect(EngineCallAudio.speaker(afterRouteTo: [.carAudio], speaker: true) == false)
        // Already off the loudspeaker: the call stays in the car.
        #expect(EngineCallAudio.speaker(afterRouteTo: [.carAudio], speaker: false) == nil)
        #expect(EngineCallAudio.speaker(afterRouteTo: [.bluetoothHFP], speaker: true) == false)
        // Choosing the loudspeaker from the call screen is still followed.
        #expect(EngineCallAudio.speaker(afterRouteTo: [.builtInSpeaker], speaker: false) == true)
        #expect(EngineCallAudio.speaker(afterRouteTo: [], speaker: true) == nil)
    }

    /// CallKit calls show in CarPlay by themselves: audio only, one at a time, in Recents.
    @Test @MainActor func theCallScreenSuitsCarPlay() {
        let configuration = PhoneCallScreen.configuration
        #expect(!configuration.supportsVideo)
        #expect(configuration.includesCallsInRecents)
        #expect(configuration.maximumCallGroups == 1)
    }
}

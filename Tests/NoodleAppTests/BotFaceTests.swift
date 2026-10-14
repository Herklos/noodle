import Foundation
import NoodleBrand
import XCTest
@testable import Noodle

@MainActor final class BotFaceTests: XCTestCase {
    func testANewBotsFaceFollowsItsNameAndKeepsOneThatStillFits() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(["Alfred": .masculine])

        // A generated name is known without asking the model; another name is guessed.
        let oscar = await f.store.fittingFace(forBotNamed: "Oscar", current: nil)
        XCTAssertEqual(oscar.flatMap(BotFaces.face(for:))?.presentation, .masculine)
        let alfred = await f.store.fittingFace(forBotNamed: "Alfred", current: nil)
        XCTAssertEqual(alfred.flatMap(BotFaces.face(for:))?.presentation, .masculine)

        // Renaming keeps the face while it still suits the name.
        let kept = await f.store.fittingFace(forBotNamed: "Owen", current: oscar)
        XCTAssertEqual(kept, oscar)
        let alex = await f.store.fittingFace(forBotNamed: "Alex", current: oscar)
        XCTAssertEqual(alex, oscar)
        let nora = await f.store.fittingFace(forBotNamed: "Nora", current: oscar)
        XCTAssertEqual(nora.flatMap(BotFaces.face(for:))?.presentation, .feminine)
    }
}

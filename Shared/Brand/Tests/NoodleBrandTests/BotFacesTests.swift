import Foundation
import Testing
@testable import NoodleBrand

@Suite struct BotFacesTests {
    @Test func everyFaceLoadsAndBothPresentationsHaveSome() {
        #expect(BotFaces.all.count == 124)
        #expect(BotFaces.all.allSatisfy { !$0.imageData.isEmpty })
        #expect(BotFaces.all.contains { $0.presentation == .feminine })
        #expect(BotFaces.all.contains { $0.presentation == .masculine })
        #expect(Set(BotFaces.all.map(\.imageData)).count == BotFaces.all.count)
    }

    @Test func generatedNamesSaySuitWhichFaces() {
        #expect(BotNameGenerator.presentation(of: "Ada") == .some(.feminine))
        #expect(BotNameGenerator.presentation(of: "oscar") == .some(.masculine))
        #expect(BotNameGenerator.presentation(of: "Alex") == .some(nil))
        #expect(BotNameGenerator.presentation(of: "Alfred") == nil)
        #expect(BotNameGenerator.presentation(of: "Clever Otter") == .some(nil))
    }

    @Test func aFaceMatchesTheNameAndSkipsFacesInUse() {
        for _ in 0..<20 {
            let face = BotFaces.random(for: .masculine, avoiding: [])
            #expect(face.flatMap(BotFaces.face(for:))?.presentation == .masculine)
        }
        let women = BotFaces.all.filter { $0.presentation == .feminine }.map(\.imageData)
        let free = women[0]
        let used = Set(women.dropFirst())
        #expect(BotFaces.random(for: .feminine, avoiding: used) == free)
        // Once every fitting face is taken, faces repeat rather than run out.
        #expect(BotFaces.random(for: .feminine, avoiding: Set(women)).map { women.contains($0) } == true)
    }

    @Test func aChosenFaceStaysWhileItStillFitsTheName() {
        let woman = BotFaces.all.first { $0.presentation == .feminine }!.imageData
        #expect(BotFaces.fits(woman, presentation: .feminine))
        #expect(BotFaces.fits(woman, presentation: nil))
        #expect(!BotFaces.fits(woman, presentation: .masculine))
        #expect(!BotFaces.fits(Data([1, 2, 3]), presentation: nil))
    }
}

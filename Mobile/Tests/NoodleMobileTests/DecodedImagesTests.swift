import Foundation
@testable import NoodleMobile
import Testing
import UIKit

@MainActor @Suite struct DecodedImagesTests {
    private static func png(_ colour: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// A card, avatar or bubble drawn again, as when scrolled back into view, does not decode its picture again.
    @Test func aPictureIsDecodedOnceHoweverOftenItIsDrawn() throws {
        let data = Self.png(.red)
        let first = try #require(DecodedImages.picture(data))
        #expect(DecodedImages.picture(data) === first)
        #expect(DecodedImages.picture(Self.png(.blue)) !== first)
    }

    /// A bubble's picture is ready the moment the bubble is drawn again, without waiting on a task.
    @Test func aFilesPreviewIsReadyWhenItComesBackIntoView() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Self.png(.green).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(DecodedImages.shown(file, at: 720) == nil)

        let loaded = try #require(DecodedImages.downsampled(file, to: 720))
        #expect(DecodedImages.shown(file, at: 720) === loaded)
        #expect(DecodedImages.shown(file, at: 96) == nil)
    }
}

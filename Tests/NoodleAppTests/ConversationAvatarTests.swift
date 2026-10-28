import CoreGraphics
import XCTest
@testable import Noodle

final class ConversationAvatarTests: XCTestCase {
    /// Member pictures off the pixel grid get resampled and look soft.
    func testGroupMembersSitOnWholePixels() {
        for scale: CGFloat in [1, 2] {
            for size: CGFloat in [20, 28, 42, 88] {
                for count in 1...3 {
                    for frame in ConversationAvatar.memberFrames(count: count, size: size, scale: scale) {
                        for value in [frame.minX, frame.minY, frame.width, frame.height] {
                            XCTAssertEqual(value * scale, (value * scale).rounded(),
                                "size \(size), \(count) members, scale \(scale): \(frame)")
                        }
                    }
                }
            }
        }
    }

    /// Two members sit diagonally across the middle, each as large as the circle allows.
    func testTwoMembersSitDiagonallyInsideTheCircle() {
        for size: CGFloat in [20, 28, 42, 88] {
            let frames = ConversationAvatar.memberFrames(count: 2, size: size, scale: 2)
            XCTAssertLessThan(frames[0].midX, frames[1].midX)
            XCTAssertLessThan(frames[0].midY, frames[1].midY)
            XCTAssertEqual((frames[0].midX + frames[1].midX) / 2, size / 2, accuracy: 0.5, "size \(size)")
            XCTAssertEqual((frames[0].midY + frames[1].midY) / 2, size / 2, accuracy: 0.5, "size \(size)")
            for frame in frames {
                let reach = hypot(frame.midX - size / 2, frame.midY - size / 2) + frame.width / 2
                XCTAssertLessThanOrEqual(reach, size / 2 + 0.5, "size \(size): \(frame)")
                XCTAssertGreaterThanOrEqual(frame.width, size * 0.58, "size \(size): \(frame)")
            }
        }
    }
}

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
}

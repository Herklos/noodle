import XCTest
@testable import Noodle

final class ConversationColumnsTests: XCTestCase {
    func testClosingColumnsPastTheVisibleOnesKeepsTheRestLoaded() {
        // Columns 4 to 6 were on screen when the space dropped to two columns.
        XCTAssertEqual(ConversationColumns.loadedColumns([4, 5, 6], visible: 4..<7, count: 2), [])
        XCTAssertEqual(ConversationColumns.loadedColumns([0, 1, 2], visible: 2..<4, count: 2), [0, 1])
        XCTAssertEqual(ConversationColumns.loadedColumns([], visible: 0..<3, count: 0), [])
    }

    func testColumnsNearTheScreenLoad() {
        XCTAssertEqual(ConversationColumns.loadedColumns([], visible: 2..<4, count: 10), [1, 2, 3, 4])
    }
}

import XCTest
@testable import HubLink

final class ConversationOrderTests: XCTestCase {
    /// Newest first, as the lists come; the odd ones are unread.
    private let items = [1, 2, 3, 4, 5]
    private func isUnread(_ item: Int) -> Bool { item % 2 == 1 }

    func testNewestFirstKeepsTheOrderGivenWithoutAnUnreadSection() {
        XCTAssertEqual(ConversationOrder.newestFirst.arranged(items, isUnread: isUnread), items)
        XCTAssertEqual(ConversationOrder.newestFirst.unread(items, isUnread: isUnread), [])
    }

    func testUnreadFirstMovesUnreadAheadAndKeepsEachPartInOrder() {
        XCTAssertEqual(ConversationOrder.unreadFirst.arranged(items, isUnread: isUnread), [1, 3, 5, 2, 4])
        XCTAssertEqual(ConversationOrder.unreadFirst.unread(items, isUnread: isUnread), [])
    }

    func testUnreadSectionTakesTheUnreadInOrderAndLeavesSectionsAlone() {
        XCTAssertEqual(ConversationOrder.unreadSection.unread(items, isUnread: isUnread), [1, 3, 5])
        XCTAssertEqual(ConversationOrder.unreadSection.arranged([2, 4], isUnread: isUnread), [2, 4])
    }

    func testUnknownStoredValueFallsBackToNewestFirst() {
        XCTAssertEqual(ConversationOrder(rawValue: "") ?? .standard, .newestFirst)
    }
}

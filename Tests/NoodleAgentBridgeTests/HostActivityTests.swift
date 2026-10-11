import NoodleAgentBridge
import XCTest

final class HostActivityTests: XCTestCase {
    private final class Transactions {
        var begun = 0, ended = 0
        var open: Int { begun - ended }
    }

    private func activity(_ transactions: Transactions) -> HostActivity {
        HostActivity(begin: { transactions.begun += 1 }, end: { transactions.ended += 1 })
    }

    func testARunningHarnessKeepsTheHostOutOfIdleExit() {
        let transactions = Transactions()
        let activity = activity(transactions)
        XCTAssertEqual(transactions.open, 0)
        var hold: HostActivity.Hold? = activity.hold()
        XCTAssertEqual(transactions.open, 1)
        withExtendedLifetime(hold) {}
        hold = nil
        XCTAssertEqual(transactions.open, 0)
    }

    func testTheHostStaysBusyUntilItsLastHarnessEnds() {
        let transactions = Transactions()
        let activity = activity(transactions)
        var first: HostActivity.Hold? = activity.hold()
        var second: HostActivity.Hold? = activity.hold()
        XCTAssertEqual(transactions.begun, 1)
        first = nil
        XCTAssertEqual(transactions.open, 1)
        second = nil
        XCTAssertEqual(transactions.open, 0)
        XCTAssertEqual(transactions.ended, 1)
        withExtendedLifetime((first, second)) {}
    }

    func testReleasingAHoldTwiceEndsItOnce() {
        let transactions = Transactions()
        let activity = activity(transactions)
        let other = activity.hold()
        let hold = activity.hold()
        hold.release()
        hold.release()
        XCTAssertEqual(transactions.open, 1)
        withExtendedLifetime(other) {}
    }
}

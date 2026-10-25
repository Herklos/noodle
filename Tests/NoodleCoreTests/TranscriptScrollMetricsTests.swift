import XCTest
@testable import NoodleCore

final class TranscriptScrollMetricsTests: XCTestCase {
    func testShortConversationWithTitlebarInsetIsAlreadyAtBottom() {
        let metrics = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 300,
                                             viewportHeight: 800, topInset: 52, bottomInset: 0)
        XCTAssertEqual(metrics.offset, 0)
        XCTAssertTrue(metrics.isAtBottom)
    }

    func testLongConversationUsesBothInsets() {
        let top = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 2000,
                                         viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertFalse(top.isAtBottom)
        let bottom = TranscriptScrollMetrics(contentOffset: 1220, contentHeight: 2000,
                                            viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertTrue(bottom.isAtBottom)
        XCTAssertEqual(bottom.offset, 1272)
        let aboveBottom = TranscriptScrollMetrics(contentOffset: 1200, contentHeight: 2000,
                                                 viewportHeight: 800, topInset: 52, bottomInset: 20)
        XCTAssertFalse(aboveBottom.isAtBottom)
    }

    func testBottomToleranceAndOverscroll() {
        for offset: CGFloat in [1198, 1200, 1208] {
            XCTAssertTrue(TranscriptScrollMetrics(contentOffset: offset, contentHeight: 2000,
                                                  viewportHeight: 800, topInset: 0, bottomInset: 0).isAtBottom)
        }
        XCTAssertEqual(TranscriptScrollMetrics(contentOffset: -70, contentHeight: 2000,
                                               viewportHeight: 800, topInset: 52, bottomInset: 0).offset, 0)
    }

    func testGrowingConversationBecomesScrollableWithoutChangingOffset() {
        let short = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 300,
                                           viewportHeight: 800, topInset: 52, bottomInset: 0)
        let long = TranscriptScrollMetrics(contentOffset: -52, contentHeight: 2000,
                                          viewportHeight: 800, topInset: 52, bottomInset: 0)
        XCTAssertTrue(short.isAtBottom)
        XCTAssertFalse(long.isAtBottom)
        XCTAssertEqual(short.offset, long.offset)
    }

    func testDistanceFromTheEnd() {
        // 2000 of content in an 800 viewport under a 52pt titlebar, 20 under the composer: the end is at 1220.
        func metrics(_ offset: CGFloat, content: CGFloat = 2000) -> TranscriptScrollMetrics {
            TranscriptScrollMetrics(contentOffset: offset, contentHeight: content, viewportHeight: 800, topInset: 52, bottomInset: 20)
        }
        XCTAssertEqual(metrics(1220).distanceFromEnd, 0)
        XCTAssertEqual(metrics(1230).distanceFromEnd, 0, "Overscrolled past the end is at it")
        XCTAssertEqual(metrics(1070).distanceFromEnd, 150)
        XCTAssertFalse(metrics(1070).isFarFromEnd, "A few lines short of the end is not far from it")
        XCTAssertTrue(metrics(820).isFarFromEnd)
        XCTAssertEqual(metrics(-52).distanceFromEnd, 1272)
        XCTAssertEqual(metrics(-52, content: 300).distanceFromEnd, 0, "A short conversation is at its end")
    }
}

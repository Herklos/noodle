import Foundation

/// Scroll geometry only; observing it must never trigger another scroll.
public struct TranscriptScrollMetrics: Equatable, Sendable {
    /// How far above the end the reader must be for Scroll to Latest to show, as on iPhone: a few lines
    /// short of the end are not reading older messages.
    public static let scrollToLatestDistance: CGFloat = 300

    public let offset: CGFloat
    public let isAtBottom: Bool
    /// How far above the end the reader is, none at or past it.
    public let distanceFromEnd: CGFloat

    public init(contentOffset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                topInset: CGFloat, bottomInset: CGFloat) {
        let adjustedOffset = contentOffset + topInset
        let maximumOffset = max(0, contentHeight + topInset + bottomInset - viewportHeight)
        offset = max(0, adjustedOffset)
        distanceFromEnd = max(0, maximumOffset - adjustedOffset)
        // A short conversation is already fully visible, even when its raw
        // offset is negative because of the titlebar/safe-area inset.
        isAtBottom = maximumOffset <= 2 || adjustedOffset >= maximumOffset - 2
    }

    /// Whether the reader is far enough above the end for Scroll to Latest.
    public var isFarFromEnd: Bool { distanceFromEnd > Self.scrollToLatestDistance }
}

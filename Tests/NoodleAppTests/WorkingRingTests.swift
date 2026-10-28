import AppKit
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class WorkingRingTests: XCTestCase {
    /// A toolbar places its items after they appear; the ring must stay around the picture, not drift with the turn.
    func testRingStaysAroundAPictureMovedAsItAppears() async throws {
        _ = NSApplication.shared
        let size: CGFloat = 40
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MovedOnAppear(size: size))
        window.contentView = host
        window.orderFront(nil)

        // The ring's middle line sits half a line plus a gap outside the picture's edge.
        let lineWidth = max(1, size * 0.045)
        let radius = size / 2 + lineWidth / 2 + max(1, size * 0.04)
        let centre = CGPoint(x: MovedOnAppear.placed + size / 2, y: MovedOnAppear.placed + size / 2)
        var worst: CGFloat = 0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(90))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            var lit = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                lit += 1
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                worst = max(worst, abs(hypot(point.x - centre.x, point.y - centre.y) - radius))
            } }
            XCTAssertGreaterThan(lit, 0, "the ring was not drawn")
        }
        XCTAssertLessThan(worst, lineWidth / 2 + 1.5, "the ring drifted off the picture")
    }
}

/// Like a toolbar item: drawn first at the corner, then moved into place as the ring starts turning.
private struct MovedOnAppear: View {
    static let placed: CGFloat = 60
    let size: CGFloat
    @State private var inPlace = false

    var body: some View {
        Color.clear.frame(width: size, height: size)
            .runtimeLook(.working, size: size)
            .padding(.leading, inPlace ? Self.placed : 0)
            .padding(.top, inPlace ? Self.placed : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { inPlace = true }
    }
}

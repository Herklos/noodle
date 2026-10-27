@testable import NoodleMobile
import SwiftUI
import Testing
import UIKit

@Suite struct WordmarkRefreshTests {
    /// The word is written as far as the list is pulled, and is whole from the threshold on.
    @Test func theWordFollowsThePull() {
        #expect(WordmarkRefresh.progress(forPull: 0) == 0)
        #expect(WordmarkRefresh.progress(forPull: WordmarkRefresh.threshold / 2) == 0.5)
        #expect(WordmarkRefresh.progress(forPull: WordmarkRefresh.threshold) == 1)
        #expect(WordmarkRefresh.progress(forPull: WordmarkRefresh.threshold * 2) == 1)
    }
}

@Suite struct PullGapTests {
    /// The refresh starts while the finger is still down, before the system holds the list open, and the
    /// word keeps to the gap the list really leaves instead of spilling over the first rows.
    @Test func theWordKeepsToTheGapWhileStillHeld() {
        var gap = PullGap()
        gap.scrolled(offset: -100, inset: 100)
        gap.scrolled(offset: -200, inset: 100)
        gap.began()
        #expect(gap.height == 100)
        #expect(gap.progress == 1)

        // Let go: the system holds the list open by however much it likes.
        gap.scrolled(offset: -164, inset: 164)
        #expect(gap.height == 64)
        #expect(gap.progress == 1)

        // Done: the word stays whole as the list goes back up.
        gap.ended()
        gap.scrolled(offset: -164, inset: 130)
        #expect(gap.height == 64)
        #expect(gap.progress == 1)
        gap.scrolled(offset: -100, inset: 100)
        #expect(gap.height == 0)

        // Back at rest, the word follows the pull again.
        gap.scrolled(offset: -140, inset: 100)
        #expect(gap.height == 40)
        #expect(gap.progress == 0.5)
    }

    /// The refresh can bring a banner above the list, as one saying a Hub cannot be reached, which moves where the
    /// list rests. Once the refresh is done and the list rests again, the word goes, instead of staying whole in the
    /// room the banner took.
    @Test func theWordGoesOnceTheListRestsAgainUnderABanner() {
        var gap = PullGap()
        gap.scrolled(offset: -100, inset: 100)
        gap.scrolled(offset: -350, inset: 100)
        gap.began()
        // Let go: the system holds the list open, and a 40-point banner comes above it.
        gap.scrolled(offset: -200, inset: 200)
        #expect(gap.progress == 1)
        gap.ended()
        // The refresh's room goes; the banner stays, and the list rests under it.
        gap.scrolled(offset: -170, inset: 140)
        #expect(gap.progress == 1, "Still on its way back up")
        gap.scrolled(offset: -140, inset: 140)
        #expect(gap.height == 0)
        #expect(gap.progress == 0)
        // From there, the word follows the pull again.
        gap.scrolled(offset: -180, inset: 140)
        #expect(gap.height == 40)
        #expect(gap.progress == 0.5)
    }
}

/// The word on a real list, pulled and let go.
@Suite(.serialized) struct WordmarkPullTests {
    /// Let go after a long pull, the list goes back up, and the word with it: none of it is left over the first
    /// rows, as deep as the pull was.
    @MainActor @Test func theWordGoesBackUpWithTheList() async throws {
        let list = NavigationStack {
            List {
                ForEach(0..<20, id: \.self) { _ in
                    Color.gray.frame(height: 60).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .wordmarkRefreshable {}
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.inline)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: list)
        window.isHidden = false
        defer { window.isHidden = true }
        await Self.layout(window)
        let scroll = try #require(Self.scrollView(in: window))
        let rest = scroll.contentOffset.y
        let top = Int(scroll.convert(CGPoint(x: 0, y: scroll.contentOffset.y + scroll.adjustedContentInset.top), to: window).y)
        let pull = 250

        scroll.contentOffset.y = rest - CGFloat(pull)
        await Self.layout(window)
        let pulled = try Self.render(window)
        #expect(Self.darkPixels(in: pulled, rows: (top + 2)..<(top + pull - 2)) > 0, "The word is written in the gap above the rows")

        // Let go: the scroll view is back at rest, drawn before anything else happens.
        scroll.contentOffset.y = rest
        let released = try Self.render(window)
        #expect(Self.darkPixels(in: released, rows: (top + 2)..<(top + pull - 2)) == 0, "The word stayed over the first rows")
    }

    @MainActor private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    @MainActor private static func layout(_ window: UIWindow) async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

    /// The window as its layers are now, at one pixel a point, in RGBA.
    @MainActor private static func render(_ window: UIWindow) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = Int(window.bounds.width), height = Int(window.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            window.layer.render(in: context)
            return true
        }
        try #require(drawn)
        return (pixels, width, height)
    }

    /// The near-black pixels in `rows`, in the middle of the window where the word is drawn: the rows are grey and
    /// the gap white, so only the word's strokes are this dark.
    private static func darkPixels(in image: (pixels: [UInt8], width: Int, height: Int), rows: Range<Int>) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < image.height {
            for x in (image.width / 2 - 70)..<(image.width / 2 + 70) {
                let index = (y * image.width + x) * 4
                if image.pixels[index + 3] > 200, image.pixels[index] < 80, image.pixels[index + 1] < 80, image.pixels[index + 2] < 80 {
                    count += 1
                }
            }
        }
        return count
    }
}

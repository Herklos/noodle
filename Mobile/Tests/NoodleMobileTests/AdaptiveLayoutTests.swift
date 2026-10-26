@testable import NoodleMobile
import SwiftUI
import Testing

/// The layouts for the iPhone Duo's cover screen, with the system's vertical bar on its right, and for wide screens.
@MainActor @Suite struct AdaptiveLayoutTests {
    /// The vertical bar's room on the iPhone Duo's cover screen.
    static let verticalBar: CGFloat = 84

    /// Beside the vertical bar the wordmark lines up with the Pair button, in the middle of the safe area,
    /// not of the whole screen under the bar.
    @Test func theWordmarkIsCentredBesideTheVerticalBar() async throws {
        let (ink, bounds, safe) = try await Self.ink(of: PairingWordmark(progress: 1), trailingInset: Self.verticalBar)
        #expect(abs(ink.midX - (safe.left + bounds.width - safe.right) / 2) < 2)
    }

    /// A short sheet beside the vertical bar spans the screen under it, so its buttons are centred in the
    /// sheet, under its grabber, rather than in the safe area left of the bar.
    @Test func aShortSheetIsCentredBesideTheVerticalBar() async throws {
        let sheet = MoreSheet { _ in }.modifier(SheetCentring(verticalBar: .some(.trailing)))
        let (ink, bounds, _) = try await Self.ink(of: sheet, trailingInset: Self.verticalBar)
        #expect(abs(ink.midX - bounds.midX) < 2)
    }

    /// Without a vertical bar a sheet keeps its safe area, as on any iPhone.
    @Test func aSheetKeepsItsSafeAreaWithoutAVerticalBar() {
        #expect(SheetCentring.ignoredEdges(verticalBar: nil) == [])
        #expect(SheetCentring.ignoredEdges(verticalBar: .trailing) == .horizontal)
        #expect(SheetCentring.ignoredEdges(verticalBar: .leading) == .horizontal)
    }

    /// Beside the vertical bar the pinned bots move into it, out of the list; without one the list shows
    /// them, as on any iPhone.
    @Test func pinnedBotsGoInTheVerticalBar() {
        #expect(HomeLayout.choose(verticalBar: .trailing) == .stackBesideBar)
        #expect(HomeLayout.choose(verticalBar: .leading) == .stackBesideBar)
        #expect(!HomeLayout.stackBesideBar.pinsInList)
        #expect(HomeLayout.choose(verticalBar: nil) == .stack)
        #expect(HomeLayout.stack.pinsInList)
    }

    /// Draws a view in a window whose safe area leaves `trailingInset` on the right, as the vertical bar
    /// does, on top of any the screen has, and finds where it put anything darker than the white behind it.
    static func ink(of view: some View, trailingInset: CGFloat) async throws -> (ink: CGRect, bounds: CGRect, safe: UIEdgeInsets) {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.ignoresSafeArea())
            .environment(\.colorScheme, .light))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: trailingInset)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))

        let bounds = host.view.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            _ = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                if pixels[pixel] < 200 || pixels[pixel + 1] < 200 || pixels[pixel + 2] < 200 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        try #require(maxX >= minX, "Nothing was drawn")
        let ink = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        return (ink, CGRect(origin: .zero, size: CGSize(width: width, height: height)), host.view.safeAreaInsets)
    }
}

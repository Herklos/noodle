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
        #expect(HomeLayout.choose(size: Self.cover, verticalBar: .trailing) == .stackBesideBar)
        #expect(HomeLayout.choose(size: Self.cover, verticalBar: .leading) == .stackBesideBar)
        #expect(!HomeLayout.stackBesideBar.pinsInList)
        #expect(HomeLayout.choose(size: Self.cover, verticalBar: nil) == .stack)
        #expect(HomeLayout.stack.pinsInList)
    }

    /// The cover screen's room beside the vertical bar, and the inner screen's, unfolded, in points inside the safe area.
    static let cover = CGSize(width: 382, height: 562), inner = CGSize(width: 951, height: 621)

    /// The unfolded iPhone Duo and iPad show the list and a conversation side by side, with the pinned bots in
    /// the list; an iPhone keeps one column, upright or on its side.
    @Test func wideScreensShowTwoColumns() {
        #expect(HomeLayout.choose(size: Self.inner, verticalBar: nil) == .split)
        #expect(HomeLayout.choose(size: Self.inner, verticalBar: .trailing) == .split)
        #expect(HomeLayout.split.pinsInList)
        // iPad mini upright, and a large iPad on its side.
        #expect(HomeLayout.choose(size: CGSize(width: 744, height: 1069), verticalBar: nil) == .split)
        #expect(HomeLayout.choose(size: CGSize(width: 1366, height: 980), verticalBar: nil) == .split)
        // An iPhone Pro Max upright and on its side, and an iPad window in a third of the screen.
        #expect(HomeLayout.choose(size: CGSize(width: 440, height: 868), verticalBar: nil) == .stack)
        #expect(HomeLayout.choose(size: CGSize(width: 838, height: 419), verticalBar: nil) == .stack)
        #expect(HomeLayout.choose(size: CGSize(width: 320, height: 980), verticalBar: nil) == .stack)
    }

    static let scout = ChatLink(hub: "Studio", thread: UUID()), house = ChatLink(hub: "Studio", thread: UUID())

    /// A tapped notification, a widget or a row pushes its conversation alone over the list in one column,
    /// and selects it beside the list in two.
    @Test func openingAConversationSelectsItInTwoColumns() {
        var navigation = HomeNavigation(path: [Self.house])
        navigation.open(Self.scout, in: .stack)
        #expect(navigation == HomeNavigation(path: [Self.scout]))

        navigation = HomeNavigation(selection: Self.house)
        navigation.open(Self.scout, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))

        navigation = HomeNavigation()
        navigation.open(Self.scout, in: .stackBesideBar)
        #expect(navigation == HomeNavigation(path: [Self.scout]))
    }

    /// A bot's profile in a group opens its conversation on top in one column, and selects it in two.
    @Test func openingFromAConversationSelectsItInTwoColumns() {
        var navigation = HomeNavigation(path: [Self.house])
        navigation.openFromConversation(Self.scout, in: .stack)
        #expect(navigation.path == [Self.house, Self.scout])
        navigation.openFromConversation(Self.house, in: .stack)
        #expect(navigation.path == [Self.house])

        navigation = HomeNavigation(selection: Self.house)
        navigation.openFromConversation(Self.scout, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))
    }

    /// Unfolding keeps the conversation that was open, now beside the list, and folding keeps the selected one open.
    @Test func changingLayoutKeepsTheConversationOpen() {
        var navigation = HomeNavigation(path: [Self.house, Self.scout])
        navigation.adapt(from: .stackBesideBar, to: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))
        navigation.adapt(from: .split, to: .stackBesideBar)
        #expect(navigation == HomeNavigation(path: [Self.scout]))
        navigation.adapt(from: .stackBesideBar, to: .stack)
        #expect(navigation == HomeNavigation(path: [Self.scout]))

        var empty = HomeNavigation()
        empty.adapt(from: .stack, to: .split)
        #expect(empty == HomeNavigation())
        empty.adapt(from: .split, to: .stack)
        #expect(empty == HomeNavigation())
    }

    /// A conversation deleted on another device closes, with any opened from it, in either layout.
    @Test func aConversationThatIsGoneCloses() {
        var navigation = HomeNavigation(path: [Self.house, Self.scout])
        navigation.remove { $0 == Self.house }
        #expect(navigation == HomeNavigation())

        navigation = HomeNavigation(selection: Self.scout)
        navigation.remove { $0 == Self.house }
        #expect(navigation == HomeNavigation(selection: Self.scout))
        navigation.remove { $0 == Self.scout }
        #expect(navigation == HomeNavigation())
    }

    /// The list takes about a third of two columns, within limits.
    @Test func theListTakesAboutAThird() {
        #expect(SplitColumns.layout(width: 744).list == 320)
        #expect(SplitColumns.layout(width: 1000).list == 360)
        #expect(SplitColumns.layout(width: 1366).list == 400)
        #expect(SplitColumns.layout(width: 1366).gap == 0)
    }

    /// On the unfolded iPhone Duo the crease divides the two columns, so neither the list nor the conversation
    /// is drawn on it.
    @Test func theCreaseDividesTheColumns() {
        let crease = CGRect(x: 466, y: -24, width: 19, height: 669)
        #expect(SplitColumns.layout(width: 951, divisions: [crease]) == SplitColumns(list: 466, gap: 19))
        // A fold across the screen, or a region near its edge, divides nothing between the columns.
        let across = CGRect(x: 0, y: 300, width: 951, height: 19)
        let edge = CGRect(x: 900, y: 0, width: 19, height: 669)
        #expect(SplitColumns.layout(width: 951, divisions: [across, edge]) == SplitColumns.layout(width: 951))
    }

    /// Messages keep the usual room beside them on a phone, and stay a readable width in a wide conversation.
    @Test func messagesStayAReadableWidth() {
        #expect(ReadableWidth.sideRoom(rowWidth: 369) == 48)
        #expect(ReadableWidth.sideRoom(rowWidth: 442) == 48)
        #expect(ReadableWidth.sideRoom(rowWidth: 942) == 942 - ReadableWidth.bubble)
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

@testable import NoodleMobile
import SwiftUI
import Testing
import UIKit

/// A hardware keyboard on iPad: going through the conversations, closing one, the spaces' shortcuts and Return
/// sending from the message field.
@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyboardCommandsTests {
    static let scout = ChatLink(hub: "Studio", thread: UUID()), house = ChatLink(hub: "Studio", thread: UUID()),
               chloe = ChatLink(hub: "Studio", thread: UUID())
    static let order = [scout, house, chloe]

    /// Next and Previous Conversation select the row below or above in two columns, from the top or the bottom
    /// when none is open, and stay at either end.
    @Test func nextAndPreviousGoThroughTheListInTwoColumns() {
        var navigation = HomeNavigation()
        navigation.step(1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))
        navigation.step(1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.house))
        navigation.step(-1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))
        navigation.step(-1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))

        navigation = HomeNavigation()
        navigation.step(-1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.chloe))
        navigation.step(1, through: Self.order, in: .split)
        #expect(navigation == HomeNavigation(selection: Self.chloe))
    }

    /// In one column the next conversation replaces the open one over the list, as tapping its row would.
    @Test func nextAndPreviousOpenTheNeighbourInOneColumn() {
        var navigation = HomeNavigation(path: [Self.house])
        navigation.step(1, through: Self.order, in: .stack)
        #expect(navigation == HomeNavigation(path: [Self.chloe]))
        navigation.step(-1, through: Self.order, in: .stackBesideBar)
        #expect(navigation == HomeNavigation(path: [Self.house]))

        // At the end the conversations opened from one another stay as they are.
        navigation = HomeNavigation(path: [Self.house, Self.chloe])
        navigation.step(1, through: Self.order, in: .stack)
        #expect(navigation == HomeNavigation(path: [Self.house, Self.chloe]))
    }

    /// A conversation the list no longer shows, as while searching, goes to the top of what it shows; an empty list
    /// changes nothing.
    @Test func aConversationNotListedStartsFromTheTop() {
        var navigation = HomeNavigation(selection: Self.house)
        navigation.step(1, through: [Self.chloe, Self.scout], in: .split)
        #expect(navigation == HomeNavigation(selection: Self.chloe))

        navigation = HomeNavigation(selection: Self.house)
        navigation.step(-1, through: [Self.chloe, Self.scout], in: .split)
        #expect(navigation == HomeNavigation(selection: Self.scout))

        navigation = HomeNavigation(selection: Self.house)
        navigation.step(1, through: [], in: .split)
        #expect(navigation == HomeNavigation(selection: Self.house))
    }

    /// Close Conversation leaves none selected in two columns, and goes back one in one column.
    @Test func closeGoesBack() {
        var navigation = HomeNavigation(selection: Self.house)
        #expect(navigation.current == Self.house)
        navigation.close()
        #expect(navigation == HomeNavigation())
        #expect(navigation.current == nil)

        navigation = HomeNavigation(path: [Self.house, Self.scout])
        #expect(navigation.current == Self.scout)
        navigation.close()
        #expect(navigation == HomeNavigation(path: [Self.house]))
        navigation.close()
        #expect(navigation == HomeNavigation())
        navigation.close()
        #expect(navigation == HomeNavigation())
    }

    /// As on the Mac: ⌘1 for All, then ⌘2 to ⌘9 for the rest in the menu's order.
    @Test func spacesHaveTheMacsNumbers() {
        #expect(SpaceCommand.shortcut(at: 0) == KeyboardShortcut("1"))
        #expect(SpaceCommand.shortcut(at: 1) == KeyboardShortcut("2"))
        #expect(SpaceCommand.shortcut(at: 8) == KeyboardShortcut("9"))
        #expect(SpaceCommand.shortcut(at: 9) == nil)
        #expect(SpaceCommand.shortcut(at: -1) == nil)
    }

    /// With a hardware keyboard Return sends from the message field, listed as Send while ⌘ is held. Shift-Return
    /// is left to the field, which starts a new line, and so is Return finishing a word being composed.
    @Test func returnSendsFromTheMessageField() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let field = PastingTextView()
        window.rootViewController?.view.addSubview(field)
        field.becomeFirstResponder()
        #expect(field.keyCommands?.contains { $0.input == "\r" } != true, "without a way to send, Return is the field's")

        var sent = 0
        field.submit = { sent += 1 }
        let send = try #require(field.keyCommands?.first { $0.input == "\r" })
        #expect(send.modifierFlags == [])
        #expect(send.title == "Send")
        #expect(send.wantsPriorityOverSystemBehavior)
        #expect(field.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags.contains(.shift) } == false)

        #expect(field.canPerformAction(send.action!, withSender: nil))
        field.sendFromKeyboard()
        #expect(sent == 1)

        field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(!field.canPerformAction(send.action!, withSender: nil), "Return finishes the word being composed")
        field.unmarkText()
        #expect(field.canPerformAction(send.action!, withSender: nil))
    }

    /// Menu commands do nothing behind a sheet, such as making a bot while one is being edited.
    @Test func commandsWaitForSheets() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(!KeyboardCommand.isPresenting(in: [window]))

        await withCheckedContinuation { done in root.present(UIViewController(), animated: false) { done.resume() } }
        #expect(KeyboardCommand.isPresenting(in: [window]))
        await withCheckedContinuation { done in root.dismiss(animated: false) { done.resume() } }
        #expect(!KeyboardCommand.isPresenting(in: [window]))
    }
}

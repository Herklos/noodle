import SwiftUI
import UIKit

/// What the keyboard's commands do on the home screen in front. Each is nil while it has nothing to do.
struct HomeCommands {
    var newBot: (() -> Void)?
    var newGroup: (() -> Void)?
    var search: (() -> Void)?
    var next: (() -> Void)?
    var previous: (() -> Void)?
    var close: (() -> Void)?
    var spaces: [SpaceCommand] = []
}

/// A space in the Spaces menu, ticked while it is shown.
struct SpaceCommand: Identifiable {
    let id: String
    let title: String
    let isShown: Bool
    let show: () -> Void

    /// ⌘1 for the first, All, to ⌘9, as on the Mac; the rest have none.
    static func shortcut(at index: Int) -> KeyboardShortcut? {
        (0..<9).contains(index) ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil
    }
}

extension FocusedValues {
    @Entry var homeCommands: HomeCommands?
}

/// The app's menus for a hardware keyboard, which holding ⌘ lists on iPad: the Mac's shortcuts where it has
/// the same command, and the arrows to go through the conversations.
struct NoodleCommands: Commands {
    @FocusedValue(\.homeCommands) private var home

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command("New Bot", home?.newBot).keyboardShortcut("n")
            command("New Group", home?.newGroup).keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Conversation") {
            command("Search Conversations", home?.search).keyboardShortcut("f")
            Divider()
            command("Next Conversation", home?.next).keyboardShortcut(.downArrow, modifiers: [.command, .option])
            command("Previous Conversation", home?.previous).keyboardShortcut(.upArrow, modifiers: [.command, .option])
            command("Close Conversation", home?.close).keyboardShortcut(.escape, modifiers: [])
        }
        if let spaces = home?.spaces, spaces.count > 1 {
            CommandMenu("Spaces") {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    Toggle(space.title, isOn: Binding(get: { space.isShown }, set: { if $0 { KeyboardCommand.run(space.show) } }))
                        .keyboardShortcut(SpaceCommand.shortcut(at: index))
                }
            }
        }
    }

    private func command(_ title: String, _ action: (() -> Void)?) -> some View {
        Button(title) { if let action { KeyboardCommand.run(action) } }
            .disabled(action == nil)
    }
}

@MainActor enum KeyboardCommand {
    /// Runs a menu command unless a sheet or full-screen view is up, which the command would act behind.
    static func run(_ action: () -> Void) {
        if !isPresenting() { action() }
    }

    static func isPresenting(in windows: [UIWindow] = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }) -> Bool {
        windows.contains { $0.rootViewController?.presentedViewController != nil }
    }
}

extension PastingTextView {
    /// With a hardware keyboard Return sends, as in Messages on iPad. Shift-Return has no command of its own, so
    /// the field starts a new line, as it does for the on-screen keyboard's return key, which is no key command.
    static var sendCommand: UIKeyCommand {
        let command = UIKeyCommand(title: "Send", action: #selector(PastingTextView.sendFromKeyboard), input: "\r", modifierFlags: [])
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}

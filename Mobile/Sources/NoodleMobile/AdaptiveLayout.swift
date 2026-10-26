import SwiftUI

/// How the home screen lays out the bots and conversations in the room it has.
enum HomeLayout: Equatable {
    /// One column: the list, with a conversation pushed over it, as on every iPhone.
    case stack
    /// One column, with the pinned bots in the system's vertical bar beside it, as on the iPhone Duo's cover screen.
    case stackBesideBar
    /// The list in a column on the left and the open conversation beside it, as on the Mac: on iPad and the
    /// unfolded iPhone Duo.
    case split

    /// Two columns need room for the list and a readable conversation, across and down: an iPhone turned on
    /// its side is wide enough, but too short, and keeps one column.
    static let splitWidth: CGFloat = 700
    static let splitHeight: CGFloat = 500

    /// The layout for the room inside the safe area, and the edge of the system's vertical bar, if there is one.
    static func choose(size: CGSize, verticalBar: HorizontalEdge?) -> HomeLayout {
        if size.width >= splitWidth, size.height >= splitHeight { return .split }
        return verticalBar == nil ? .stack : .stackBesideBar
    }

    /// Whether the list shows the pinned bots above the others; beside the vertical bar they are in the bar.
    var pinsInList: Bool { self != .stackBesideBar }
}

/// Which conversation is open: pushed over the list in one column, or selected beside it in two.
struct HomeNavigation: Equatable {
    /// The conversations over the list in one column, the latest on top.
    var path: [ChatLink] = []
    /// The conversation beside the list in two columns.
    var selection: ChatLink?

    /// Opens a conversation from the list, a notification, a widget or a link, alone over the list or beside it.
    mutating func open(_ link: ChatLink, in layout: HomeLayout) {
        if layout == .split {
            selection = link
            path = []
        } else {
            path = [link]
            selection = nil
        }
    }

    /// Opens a conversation from another, as a bot's profile in a group does: in one column on top, or back to
    /// it when it is open beneath; in two it is selected, as a row tapped in the list is.
    mutating func openFromConversation(_ link: ChatLink, in layout: HomeLayout) {
        if layout == .split {
            open(link, in: layout)
        } else {
            path = ChatLink.path(path, opening: link)
        }
    }

    /// The conversation on top stays open when the layout changes, as when the iPhone Duo is unfolded or folded,
    /// or an iPad window is resized.
    mutating func adapt(from old: HomeLayout, to new: HomeLayout) {
        switch (old == .split, new == .split) {
        case (false, true):
            selection = path.last
            path = []
        case (true, false):
            path = selection.map { [$0] } ?? []
            selection = nil
        default:
            break
        }
    }

    /// Closes a conversation that is gone, and any opened from it.
    mutating func remove(where gone: (ChatLink) -> Bool) {
        if let selection, gone(selection) { self.selection = nil }
        if let index = path.firstIndex(where: gone) { path = Array(path[..<index]) }
    }
}

/// The width of the list's column on the left of two.
struct SplitColumns: Equatable {
    var list: CGFloat

    static let narrowest: CGFloat = 320, widest: CGFloat = 400

    /// The list takes about a third, as on the Mac.
    static func layout(width: CGFloat) -> SplitColumns {
        SplitColumns(list: min(max(width * 0.36, narrowest), widest))
    }
}

/// How wide a message gets in a wide conversation, so its lines stay short enough to read.
enum ReadableWidth {
    static let bubble: CGFloat = 560
    /// The least room beside a message, on the side away from its author, as in Messages.
    static let sideRoom: CGFloat = 48

    /// The room beside a message in a row this wide: at least the usual, and enough to keep it readable.
    static func sideRoom(rowWidth: CGFloat) -> CGFloat { max(sideRoom, rowWidth - bubble) }
}

/// The edge of the system's vertical bar, as on the iPhone Duo's cover screen, from iOS 27.1; nil elsewhere.
struct VerticalBarReader: ViewModifier {
    @Binding var edge: HorizontalEdge?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reading(edge: $edge))
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Reading: ViewModifier {
        @Binding var edge: HorizontalEdge?
        @Environment(\.toolbarVerticalEdge) private var verticalEdge

        func body(content: Content) -> some View {
            content.onChange(of: verticalEdge, initial: true) { edge = verticalEdge }
        }
    }
}

extension View {
    /// Tells `edge` where the system's vertical bar is, or nil when there is none.
    func readingVerticalBar(_ edge: Binding<HorizontalEdge?>) -> some View { modifier(VerticalBarReader(edge: edge)) }

    /// Centres a short sheet's content in the sheet beside the system's vertical bar.
    func centredInSheet() -> some View { modifier(SheetCentring()) }
}

/// Beside the iPhone Duo's vertical bar a short sheet spans the screen, under the bar, but keeps the bar's
/// room as safe area on that side, so its content would sit off the middle of the sheet and its grabber.
/// There the content takes the sheet's whole width; elsewhere it keeps the safe area, clear of the Dynamic Island.
struct SheetCentring: ViewModifier {
    /// Where the vertical bar is; read from the system unless given.
    var verticalBar: HorizontalEdge??
    @State private var reading: HorizontalEdge?

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: Self.ignoredEdges(verticalBar: verticalBar ?? reading))
            .readingVerticalBar($reading)
    }

    static func ignoredEdges(verticalBar: HorizontalEdge?) -> Edge.Set { verticalBar == nil ? [] : .horizontal }
}

import SwiftUI

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

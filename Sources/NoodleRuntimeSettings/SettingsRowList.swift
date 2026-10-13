import AppKit
import SwiftUI
import NoodleCore

/// Keeps a settings group compact while allowing rows with wrapped status or
/// error text to use their full height inside the scrollable area.
public struct SettingsRowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    /// The form's trailing row inset, the most the section shows past a row.
    private let sectionMargin: CGFloat = 10

    public var body: some View {
        SettingsBotListLayout {
            ViewThatFits(in: .vertical) {
                rows
                // The scroll bar sits on the section's edge. An overlay bar
                // floats over the margin; a legacy one takes its own width,
                // so the rows give up only what the margin cannot cover.
                ScrollView {
                    rows
                        .padding(.trailing, scrollerStyle == .overlay ? sectionMargin : 0)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.trailing, -sectionMargin)
            }
        }
        .toggleStyle(.switch)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }

    public init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }
}

/// Propose the height limit during measurement, including when the Settings
/// window or a popover asks for its ideal size. No later state update should
/// resize the tab.
public struct SettingsBotListLayout: Layout {
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: 360))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

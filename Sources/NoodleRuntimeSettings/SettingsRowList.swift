import SwiftUI
import NoodleCore

/// Keeps a settings group compact while allowing rows with wrapped status or
/// error text to use their full height inside the scrollable area.
public struct SettingsRowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    public var body: some View {
        SettingsBotListLayout {
            ViewThatFits(in: .vertical) {
                rows
                // The section clips anything past the row, so the scroll bar
                // has to stay inside it to be seen.
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .toggleStyle(.switch)
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

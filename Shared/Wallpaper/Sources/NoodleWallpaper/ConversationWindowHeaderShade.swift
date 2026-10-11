import SwiftUI

private let conversationTopFadeHeight: CGFloat = 64

/// Fade scrolling content beneath the toolbar to reveal the shaded wallpaper.
/// Apply this mask to the detail scroll view, leaving the sidebar untouched.
public struct ConversationContentTopFade: View {
    /// Where the fade reaches full opacity, measured from the content's top.
    public static let height = conversationTopFadeHeight

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.12), location: 0.45),
                .init(color: .white, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: conversationTopFadeHeight)
            Color.white
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// An edge-to-edge fade on the wallpaper, underneath both split-view columns.
/// It must not wash over sidebar content or stop at the conversation boundary.
public struct ConversationWindowHeaderShade: View {
    public init() {}
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.06), location: 0),
                    .init(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.03), location: 0.5),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.55),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: conversationTopFadeHeight)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.06), radius: 14, y: 5)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

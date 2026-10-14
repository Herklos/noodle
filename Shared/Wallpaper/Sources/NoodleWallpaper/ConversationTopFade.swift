import SwiftUI

public extension View {
    /// Fade scrolling content into the wallpaper as it passes beneath the toolbar, and only
    /// while there is content beneath it. Apply to a scroll view that runs up behind the
    /// toolbar, leaving the sidebar untouched.
    func conversationTopFade() -> some View { modifier(ConversationTopFade()) }
}

private struct ConversationTopFade: ViewModifier {
    /// How far below the toolbar the fade reaches full opacity.
    private static let overhang: CGFloat = 24
    @State private var strength: Double = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Double.self) { geometry in
                // Full strength once content has scrolled a toolbar's height under the toolbar.
                let underBar = geometry.contentOffset.y + geometry.contentInsets.top
                return min(max(underBar / max(geometry.contentInsets.top, 1), 0), 1)
            } action: { _, strength in
                self.strength = strength
            }
            .mask {
                GeometryReader { geometry in
                    TopFadeMask(length: geometry.safeAreaInsets.top + Self.overhang, strength: strength)
                        .ignoresSafeArea()
                }
            }
    }
}

/// Opaque below the toolbar, clear at the window top, eased so content stays solid until
/// it nears the edge. Strength 0 leaves the content untouched.
private struct TopFadeMask: View {
    let length: CGFloat
    let strength: Double

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: (0...16).map { step in
                let t = Double(step) / 16
                let eased = t * t * (3 - 2 * t)
                return .init(color: .black.opacity(1 - strength * (1 - eased)), location: t)
            }, startPoint: .top, endPoint: .bottom)
            .frame(height: max(length, 1))
            Color.black
        }
    }
}

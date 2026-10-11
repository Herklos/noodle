import AppKit
import SwiftUI
@_exported import NoodleWallpaperCore

/// One window-sized wallpaper. Load its replacement before fading so image-backed
/// conversations never flash the default canvas during a switch. Wallpapers are dark
/// scenes, so the window turns dark while one is shown, whatever the system says.
public struct ConversationWallpaper: View {
    let background: ConversationBackground
    var imageURL: URL?
    public init(background: ConversationBackground, imageURL: URL? = nil) {
        self.background = background; self.imageURL = imageURL
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = Layer(request: Request(background: ConversationBackground()))

    private struct Request: Equatable {
        let background: ConversationBackground
        var imageURL: URL?
    }

    private struct Layer: Identifiable {
        let id = UUID()
        let request: Request
        var image: NSImage?
    }

    public var body: some View {
        let request = Request(background: background, imageURL: imageURL)
        ZStack {
            systemCanvas
            ConversationBackgroundView(background: displayed.request.background,
                imageURL: displayed.request.imageURL, previewImage: displayed.image)
                .id(displayed.id)
                .transition(.opacity)
                .zIndex(1)
        }
        .background(WallpaperWindowAppearance(isDark: !background.isDefault))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard request != displayed.request else { return }
            let image: NSImage?
            if let url = request.imageURL {
                let kind = request.background.mediaKind
                let poster = await Task.detached { await BackgroundMedia.poster(at: url, kind: kind) }.value
                image = poster.map { NSImage(cgImage: $0, size: .zero) }
            } else {
                image = nil
            }
            guard !Task.isCancelled else { return }
            // Keep this transaction local to the wallpaper, not the transcript.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                displayed = Layer(request: request, image: image)
            }
        }
    }
}

public struct ConversationBackgroundView: View {
    let background: ConversationBackground
    var imageURL: URL?
    var previewImage: NSImage?
    public init(background: ConversationBackground, imageURL: URL? = nil, previewImage: NSImage? = nil) {
        self.background = background; self.imageURL = imageURL; self.previewImage = previewImage
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedImage: NSImage?

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                systemCanvas
                if let image = previewImage ?? loadedImage, background.imageFilename != nil {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let preset = background.preset {
                    LinearGradient(colors: colors(preset), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(colors(preset)[1].opacity(0.5))
                        .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                        .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35)
                        .blur(radius: 50)
                }
                if let imageURL, let kind = background.mediaKind, kind != .image {
                    AnimatedWallpaper(url: imageURL, kind: kind, reduceMotion: reduceMotion)
                }
                if !background.isDefault { Color.black.opacity(0.25) }
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            loadedImage = nil
            guard let imageURL, previewImage == nil else { return }
            let kind = background.mediaKind
            let poster = await Task.detached { await BackgroundMedia.poster(at: imageURL, kind: kind) }.value
            guard !Task.isCancelled else { return }
            loadedImage = poster.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private func colors(_ preset: ConversationBackgroundPreset) -> [Color] {
        switch preset {
        case .sunset: return [Color(red: 0.96, green: 0.52, blue: 0.15), Color(red: 0.77, green: 0.43, blue: 0.67), Color(red: 0.46, green: 0.35, blue: 0.75)]
        case .ocean: return [Color(red: 0.04, green: 0.26, blue: 0.50), Color(red: 0.08, green: 0.60, blue: 0.66), Color(red: 0.14, green: 0.30, blue: 0.62)]
        case .forest: return [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.34, green: 0.53, blue: 0.30), Color(red: 0.14, green: 0.34, blue: 0.39)]
        case .dusk: return [Color(red: 0.18, green: 0.16, blue: 0.39), Color(red: 0.47, green: 0.29, blue: 0.60), Color(red: 0.73, green: 0.37, blue: 0.47)]
        }
    }
}

/// The default canvas in the system's appearance rather than the window's. A window that
/// turns dark for a wallpaper keeps this colour beneath the wallpaper fading in, not black.
@MainActor private var systemCanvas: Color {
    var color = NSColor.textBackgroundColor
    NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
        color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
    }
    return Color(nsColor: color)
}

/// Crossfades the whole window, chrome included, when its appearance changes.
private struct WallpaperWindowAppearance: NSViewRepresentable {
    let isDark: Bool

    final class Probe: NSView {
        var isDark = false { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        private func apply() {
            guard let window else { return }
            let appearance = isDark ? NSAppearance(named: .darkAqua) : nil
            guard window.appearance?.name != appearance?.name else { return }
            if window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               let frame = window.contentView?.superview?.layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.35
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                frame.add(fade, forKey: Self.fadeKey)
            }
            window.appearance = appearance
        }

        static let fadeKey = "noodle.wallpaper-appearance"
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.isDark = isDark }
}


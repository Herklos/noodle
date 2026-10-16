import HubLink
import ImageIO
import SwiftUI
import UIKit

/// A bot as its avatar shows it: its picture, or its symbol on its colour.
struct BotFace: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var picture: Data?
    var symbol: String?
    var colour: Int

    init(_ draft: LinkBotDraft, id: UUID) {
        self.id = id
        name = draft.name
        picture = draft.avatarImageData
        symbol = draft.avatarSymbolName
        colour = draft.avatarColorIndex
    }

    init(_ bot: LinkBot) { self.init(bot.draft, id: bot.id) }
}

/// The bot's picture, or its symbol on its colour, as Noodle on the Mac shows it.
struct AgentAvatar: View {
    /// The same gradients as the Mac's bot avatars, indexed the same way.
    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
    ]
    let face: BotFace
    let size: CGFloat
    /// Shown as a dot in the corner, as on the Mac. Nil shows none.
    var phase: LinkBotPhase?

    init(face: BotFace, size: CGFloat, phase: LinkBotPhase? = nil) {
        self.face = face
        self.size = size
        self.phase = phase
    }

    init(draft: LinkBotDraft, size: CGFloat, phase: LinkBotPhase? = nil) {
        self.init(face: BotFace(draft, id: UUID()), size: size, phase: phase)
    }

    static var colourCount: Int { gradients.count }

    /// The Mac's colours: working blue, failed red, ready green, anything else grey.
    static func colour(of phase: LinkBotPhase) -> Color {
        switch phase {
        case .working: .blue
        case .failed: .red
        case .ready: .green
        case .offline, .starting: .gray
        }
    }

    /// Bots may store any integer; it wraps onto the palette.
    static func colourIndex(_ colour: Int) -> Int { Int(colour.magnitude % UInt(gradients.count)) }

    static func swatch(_ index: Int) -> some View {
        Circle().fill(LinearGradient(colors: gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        Group {
            if let data = face.picture, let image = DecodedImages.picture(data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Self.swatch(Self.colourIndex(face.colour))
                    .overlay {
                        Image(systemName: face.symbol ?? "sparkles")
                            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let phase {
                let dot = max(8, size * 0.24)
                Circle().fill(Self.colour(of: phase))
                    .frame(width: dot, height: dot)
                    .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                    .accessibilityLabel(phase.rawValue.capitalized)
            }
        }
        .accessibilityHidden(phase == nil)
    }
}

/// A group's picture: its first bots together, as Noodle on the Mac shows a group.
struct GroupAvatar: View {
    let faces: [BotFace]
    let size: CGFloat

    var body: some View {
        if faces.count == 1, let face = faces.first {
            // One bot in front of a disc, so it still reads as a group.
            ZStack {
                Circle().fill(.quaternary).frame(width: size * 0.88, height: size * 0.88)
                    .offset(x: size * 0.06, y: size * 0.06)
                AgentAvatar(face: face, size: size * 0.86)
                    .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                    .offset(x: -size * 0.06, y: -size * 0.06)
            }
            .frame(width: size, height: size)
        } else {
            ZStack {
                Circle().fill(.quaternary)
                ForEach(Array(faces.prefix(3).enumerated()), id: \.offset) { index, face in
                    AgentAvatar(face: face, size: size * 0.62)
                        .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                        .offset(Self.offset(index, size: size))
                }
            }
            .frame(width: size, height: size)
        }
    }

    private static func offset(_ index: Int, size: CGFloat) -> CGSize {
        switch index {
        case 0: CGSize(width: -size * 0.18, height: -size * 0.14)
        case 1: CGSize(width: size * 0.18, height: -size * 0.14)
        default: CGSize(width: 0, height: size * 0.19)
        }
    }
}

/// Pictures decoded once and kept while memory allows, so a bubble, card or avatar drawn again, as
/// when scrolled back into view, shows at once rather than decoding again on the main thread.
enum DecodedImages {
    private nonisolated(unsafe) static let pictures: NSCache<NSData, UIImage> = cache()
    private nonisolated(unsafe) static let files: NSCache<NSString, UIImage> = cache()

    private static func cache<Key>() -> NSCache<Key, UIImage> {
        let cache = NSCache<Key, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }

    /// What it takes in memory, so the caches stay within their limit.
    private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// The picture in these bytes, decoded ready to draw.
    static func picture(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let image = pictures.object(forKey: key) { return image }
        guard let decoded = UIImage(data: data) else { return nil }
        let image = decoded.preparingForDisplay() ?? decoded
        pictures.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// A file's picture as decoded at this size before, if it still is.
    static func shown(_ file: URL, at pixels: Int) -> UIImage? {
        files.object(forKey: key(file, pixels))
    }

    static func keep(_ image: UIImage, of file: URL, at pixels: Int) {
        files.setObject(image, forKey: key(file, pixels), cost: cost(of: image))
    }

    /// Decodes only as many pixels as are shown, once.
    static func downsampled(_ file: URL, to pixels: Int) -> UIImage? {
        if let image = shown(file, at: pixels) { return image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: decoded)
        keep(image, of: file, at: pixels)
        return image
    }

    private static func key(_ file: URL, _ pixels: Int) -> NSString { "\(pixels) \(file.path)" as NSString }
}

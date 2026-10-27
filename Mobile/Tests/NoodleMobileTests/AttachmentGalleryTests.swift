import Foundation
import HubLink
import SwiftUI
import UIKit
@testable import NoodleMobile
import Testing

/// Opening one file of a message lets you swipe through the other files in it.
struct AttachmentGalleryTests {
    private func file(_ name: String, voice: Bool = false, url: String? = nil) -> LinkAttachment {
        LinkAttachment(id: UUID(), filename: name, mediaType: "application/octet-stream", byteCount: 1,
                       voice: voice ? LinkVoice(transcript: nil, duration: 1, waveform: [], localeIdentifier: nil) : nil,
                       url: url.flatMap(URL.init(string:)))
    }

    @Test func filesOfAMessageSwipeTogetherWithoutLinksOrVoice() {
        let one = file("One.png"), two = file("Two.pdf")
        let voice = file("Voice.m4a", voice: true), link = file("Site.webloc", url: "https://example.com")
        #expect(LinkAttachment.previewGallery(opening: two, among: [one, voice, link, two]).map(\.id) == [one.id, two.id])
        #expect(LinkAttachment.previewGallery(opening: link, among: [one, link, two]).map(\.id) == [link.id])
    }

    /// Only files you swipe through together share a stack; a noodlet or a voice message sits on its own.
    @Test func onlyFilesThatSwipeTogetherShareALayout() {
        let noodlet = file("Explainer", url: "noodlet://explainer"), voice = file("Voice.m4a", voice: true)
        let one = file("One.png"), two = file("Two.png")
        let parts = LinkAttachment.arranged([noodlet, one, voice, two])
        #expect(parts.alone.map(\.id) == [noodlet.id, voice.id])
        #expect(parts.together.map(\.id) == [one.id, two.id])
    }

    /// Tapping a file waiting above the message field opens it, and the others waiting swipe with it, in order.
    @Test func aWaitingFileOpensWithTheOthersWaiting() {
        let photo = OutgoingFile(url: URL(fileURLWithPath: "/tmp/Photo.png"), filename: "Photo.png", mediaType: "image/png")
        let notes = OutgoingFile(url: URL(fileURLWithPath: "/tmp/Notes.pdf"), filename: "Notes.pdf", mediaType: "application/pdf")
        #expect(PendingFileChip.gallery(of: [photo, notes]) == [photo.url, notes.url])
        #expect(PendingFileChip.gallery(of: []).isEmpty)
    }

    /// As drawn: in Stack a noodlet sits whole above the pictures, and only the pictures overlap.
    @MainActor @Test func stackLeavesANoodletUncovered() throws {
        let items = [file("Explainer", url: "noodlet://explainer"), file("One.png"), file("Two.png")]
        let colors: [Color] = [.red, .green, .blue]
        let view = MessageAttachments(attachments: items, mode: .stack, trailing: false) { item, _ in
            colors[items.firstIndex { $0.id == item.id }!].frame(width: 150, height: 200)
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        let image = try #require(renderer.cgImage)
        #expect(image.width == 213)
        #expect(image.height == 420)
        #expect(try Self.pixel(of: image, x: 140, y: 190).red > 200, "Nothing may cover the noodlet")
        #expect(try Self.pixel(of: image, x: 30, y: 300).green > 100, "The first picture shows below it")
    }

    /// Wrap and Vertical keep every file in message order, as before.
    @MainActor @Test func otherLayoutsKeepMessageOrder() throws {
        let items = [file("Explainer", url: "noodlet://explainer"), file("One.png")]
        let view = MessageAttachments(attachments: items, mode: .wrap, trailing: false) { _, _ in
            Color.red.frame(width: 150, height: 200)
        }
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 308)
        #expect(image.height == 200)
    }

    private static func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }
}

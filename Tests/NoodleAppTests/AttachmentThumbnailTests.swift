import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Noodle

@MainActor final class AttachmentThumbnailTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnails-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Scrolling back to a picture after memory was reclaimed reads a small copy, not the original.
    func testAThumbnailIsDecodedOnceAtTheSizeItIsShown() throws {
        let original = root.appendingPathComponent("photo.png"), cache = root.appendingPathComponent("Cache")
        try writePNG(width: 2_400, height: 1_200, to: original)
        let decodes = AttachmentThumbnailCache.decodes
        let first = try XCTUnwrap(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        let pixels = try XCTUnwrap(first.representations.first)
        XCTAssertLessThanOrEqual(max(pixels.pixelsWide, pixels.pixelsHigh), 600)
        XCTAssertNotNil(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        XCTAssertEqual(AttachmentThumbnailCache.decodes, decodes + 1)

        // A changed original gets a new thumbnail.
        try FileManager.default.removeItem(at: original)
        try writePNG(width: 1_200, height: 2_400, to: original)
        let second = try XCTUnwrap(AttachmentThumbnailCache.thumbnail(for: original, cacheDirectory: cache))
        XCTAssertEqual(AttachmentThumbnailCache.decodes, decodes + 2)
        let size = try XCTUnwrap(second.representations.first)
        XCTAssertGreaterThan(size.pixelsHigh, size.pixelsWide)
    }

    /// A bubble is rebuilt many times while scrolling; its file is opened once to see if it is a picture.
    func testWhetherAFileIsAPictureIsReadOnce() throws {
        let file = root.appendingPathComponent("unlabelled.bin")
        try writePNG(width: 4, height: 4, to: file)
        let reads = AttachmentThumbnailCache.headerReads
        XCTAssertTrue(AttachmentThumbnailCache.isImage(file))
        XCTAssertTrue(AttachmentThumbnailCache.isImage(file))
        XCTAssertEqual(AttachmentThumbnailCache.headerReads, reads + 1)
    }
}

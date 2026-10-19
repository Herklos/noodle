import AVFoundation
import BrowserCore
@testable import NoodleBrowser
import WebKit
import XCTest

/// Mute silences a browser; it does not stop its pages. Sites that decode video in the page, such
/// as an upload making its cover, must keep working in a browser that is muted, as new ones are.
final class BrowserMuteTests: XCTestCase {
    @MainActor func testMutingSilencesVideoWithoutPausingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work")
        XCTAssertTrue(browser.muted, "new browsers start muted")
        let tab = try runtime.makeTab(browserID: browser.id)
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/muted-video.html")
        tab.web.loadHTMLString(try String(contentsOf: page, encoding: .utf8), baseURL: nil)
        guard try await waitFor("the fixture page", { try await Self.run(tab, "typeof start") as? String == "function" }) else { return }
        let video = try await Self.redVideo()
        _ = try await tab.web.callAsyncJavaScript("start(bytes); window.loaded = true", arguments: ["bytes": video.base64EncodedString()], contentWorld: .page)

        guard try await waitFor("muted video to play", { try await Self.time(tab) >= 1 }) else { return }
        let started = try await Self.run(tab, "window.started") as? String
        XCTAssertEqual(started, "playing")
        // WebKit may have no frame to hand a canvas on the first draw, so the page draws until it does.
        var pixel: [Int] = []
        let drawn = try await waitFor("a red frame drawn to a canvas", {
            pixel = try await Self.run(tab, "frame()") as? [Int] ?? []
            return pixel.count == 4 && pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
        })
        XCTAssertTrue(drawn, "the last frame drawn to a canvas is \(pixel)")
        XCTAssertTrue(Self.silenced(tab), "a muted browser's page can be heard")

        try await runtime.setMuted(false, browserID: browser.id)
        XCTAssertFalse(Self.silenced(tab))
        let unmuted = try await Self.time(tab)
        guard try await waitFor("unmuted video to keep playing", { try await Self.time(tab) != unmuted }) else { return }
        let kept = try await Self.run(tab, "window.loaded === true") as? Bool
        XCTAssertEqual(kept, true, "unmuting reloaded the page")

        try await runtime.setMuted(true, browserID: browser.id)
        XCTAssertTrue(Self.silenced(tab))
        let muted = try await Self.time(tab)
        guard try await waitFor("video muted again to keep playing", { try await Self.time(tab) != muted }) else { return }
        XCTAssertTrue(Self.silenced(try runtime.makeTab(browserID: browser.id)), "a new tab of a muted browser can be heard")
    }

    /// WebKit's own muted state, so the test pins the silence and not the browser's setting.
    @MainActor private static func silenced(_ tab: BrowserTab) -> Bool {
        ((tab.web.value(forKey: "mediaMutedState") as? NSNumber)?.uintValue ?? 0) & 1 == 1
    }

    @MainActor private static func run(_ tab: BrowserTab, _ expression: String) async throws -> Any? {
        try await tab.web.callAsyncJavaScript("return \(expression)", contentWorld: .page)
    }

    @MainActor private static func time(_ tab: BrowserTab) async throws -> Double {
        try await run(tab, "video.currentTime") as? Double ?? 0
    }

    @MainActor private func waitFor(_ what: String, _ done: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<300 { if try await done() { return true }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Timed out waiting for \(what)"); return false
    }

    /// Three seconds of red, without sound, made here so the test needs no media file or network.
    private static func redVideo() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &made)
            let buffer = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 { let pixel = base + y * row + x * 4; pixel[0] = 0; pixel[1] = 0; pixel[2] = 255; pixel[3] = 255 }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return try Data(contentsOf: url)
    }
}

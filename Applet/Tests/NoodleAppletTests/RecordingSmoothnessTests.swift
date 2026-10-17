import AVFoundation
import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// Something moving at a steady pace in a noodlet has to move by the same amount in every frame of
/// its recording, out of sight and however busy the Mac is. Recordings used to sample the page as
/// it ran, so a late capture showed a frame twice and the next one jumped.
@MainActor final class RecordingSmoothnessTests: XCTestCase {
    /// Four bars cross the page at 120 points a second, 4 points a frame at 30 frames a second: one
    /// placed from performance.now, one from Date, one stepped by a timer and one by a CSS animation.
    static let page = """
        <title>Bars</title><style>
        body { margin: 0; background: #000; overflow: hidden }
        .bar { position: absolute; left: 0; width: 16px; height: 40px; background: #fff }
        @keyframes slide { from { transform: translateX(0) } to { transform: translateX(600px) } }
        #css { top: 160px; animation: slide 5s linear infinite }
        </style>
        <div class=bar id=clock style="top: 10px"></div><div class=bar id=date style="top: 60px"></div>
        <div class=bar id=timer style="top: 110px"></div><div class=bar id=css></div>
        <script>
        const bar = id => document.getElementById(id);
        const place = (id, x) => bar(id).style.transform = `translateX(${x % 600}px)`;
        const begun = performance.now(), dated = Date.now();
        let ticks = 0;
        setInterval(() => place('timer', ++ticks * 4), 1000 / 30);
        const draw = () => {
          place('clock', (performance.now() - begun) * 0.12);
          place('date', (Date.now() - dated) * 0.12);
          requestAnimationFrame(draw);
        };
        requestAnimationFrame(draw);
        </script>
        """
    /// The middle row of each bar's lane, top to bottom.
    static let lanes = [("performance.now", 30), ("Date", 80), ("timer", 130), ("CSS animation", 180)]

    func testABarMovingSteadilyMovesTheSameDistanceInEveryFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RecordingSmoothness." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let identity = AppletBuildIdentity.current.noodleID
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet([
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Bars")),
            "index.html": Data(Self.page.utf8),
        ], named: "Bars", owner: "author", root: root)
        validate.owner = "author"
        let installed = try await runtime.handle(validate, identity: identity).checked()
        var open = AppletRequest(.open)
        open.path = try library.package(for: try XCTUnwrap(installed.noodletID)).url.path
        open.owner = "author"
        open.mode = "background"
        open.width = 640
        open.height = 220
        let started = try await runtime.handle(open, identity: identity).checked()
        let sessionID = try XCTUnwrap(started.sessionID)
        let session = try XCTUnwrap(runtime.sessions[sessionID])
        defer { session.stop() }
        // Let the page settle and the bars get going.
        try await Task.sleep(for: .milliseconds(500))

        var record = AppletRequest(.recordStart)
        record.sessionID = sessionID
        record.duration = 2
        _ = try await runtime.handle(record, identity: identity).checked()
        try await Task.sleep(for: .milliseconds(2200))
        var stop = AppletRequest(.recordStop)
        stop.sessionID = sessionID
        _ = try await runtime.handle(stop, identity: identity).checked()
        // The page runs on its own clock again, carrying on from where the recording left it.
        let web = try XCTUnwrap(session.web)
        let before = try await web.evaluate("return [ticks, performance.now(), document.getAnimations()[0].playState]")
        try await Task.sleep(for: .milliseconds(1200))
        let after = try await web.evaluate("return [ticks, performance.now(), document.getAnimations()[0].playState]")
        let (was, now) = try (Self.decode(before), Self.decode(after))
        XCTAssertGreaterThan(now.ticks, was.ticks, "The page's timers stopped after the recording.")
        XCTAssertGreaterThan(now.time, was.time + 1000, "The page's clock stopped after the recording.")
        XCTAssertEqual(now.animation, "running", "The page's animation stopped after the recording.")

        let captures = root.appendingPathComponent("Captures")
        let video = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "mp4" })
        let frames = try await Self.frames(video, rows: Self.lanes.map(\.1)).map(\.positions)
        XCTAssertEqual(frames.count, 60, "A two-second recording has \(frames.count) frames.")
        for (lane, (name, _)) in Self.lanes.enumerated() {
            let steps = zip(frames, frames.dropFirst()).map { previous, next in
                // A bar that reached the end of its lane starts again from the left.
                let step = next[lane] - previous[lane]
                return step < -300 ? step + 600 : step
            }
            let uneven = steps.filter { abs($0 - 4) > 1 }
            print("INFO \(name): \(frames.count) frames, \(uneven.count) uneven steps: \(steps)")
            XCTAssertTrue(uneven.isEmpty, "The \(name) bar moved unevenly: \(steps)")
        }
    }

    private static func decode(_ json: String) throws -> (ticks: Int, time: Double, animation: String) {
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        return (try XCTUnwrap(values[0] as? Int), try XCTUnwrap(values[1] as? Double), try XCTUnwrap(values[2] as? String))
    }

    /// Each frame in order, with where its bar starts in each of `rows`: the first bright pixel
    /// from the left, or -1 for none.
    static func frames(_ url: URL, rows: [Int]) async throws -> [(time: CMTime, positions: [Int])] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [(time: CMTime, positions: [Int])] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer)
            frames.append((sample.presentationTimeStamp, rows.map { row in
                (0..<width).first { base[row * stride + $0 * 4 + 1] > 128 } ?? -1
            }))
        }
        return frames.sorted { $0.time < $1.time }
    }
}

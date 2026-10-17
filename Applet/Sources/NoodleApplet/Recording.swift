import AVFoundation
import AppKit
import AppletBridge
import CoreImage

@MainActor final class AppletRecording {
    /// How a recording films a page frame by frame on a clock of the page's own, so every frame
    /// shows the page at exactly its own time however long capturing it takes.
    struct Film {
        /// Puts the page on the film's clock; false leaves it on its own, recorded as it runs.
        var begin: @MainActor () async -> Bool
        /// Moves the page's clock on by one frame.
        var advance: @MainActor () async throws -> Void
        /// Gives the page its own clock back.
        var end: @MainActor () async -> Void
    }
    let url: URL
    /// The picture is written as it is captured; the sound joins it when the recording ends.
    private let videoURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let drawer = FrameDrawer()
    let size: CGSize
    private let film: Film?
    private var frames: Int64 = 0
    private var task: Task<Void, Never>?
    private var failure: Error?
    /// Keeps macOS from napping Applet while the recording runs, which would delay every frame.
    private var activity: NSObjectProtocol?
    /// When capturing started, and for how long it was asked to run.
    private var started: ContinuousClock.Instant?
    private var duration = 0.0
    /// What the noodlet played, interleaved stereo at audioRate, from the start of the recording.
    private var sound: [Int16] = []
    private var limit = 0
    /// Frames are timed on a grid of this many slots per second, so playback is even. Filmed, every
    /// slot has its frame. A noodlet recorded as it runs that cannot be captured this fast lands
    /// on every second or third slot instead, which stays even and keeps the recording in real time.
    nonisolated static let framesPerSecond: Int32 = 30
    /// Runners hand over sound in this one format, so the recording needs no converter.
    nonisolated static let audioRate = 48000.0
    /// A film stopped once its time is up but still owing frames, because filming fell behind real
    /// time, is given this much longer to finish them.
    nonisolated static let catchUp = Duration.seconds(10)
    init(url: URL, size: CGSize, film: Film? = nil) throws {
        self.url = url
        self.film = film
        videoURL = url.deletingPathExtension().appendingPathExtension("video.mp4")
        self.size = CGSize(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
        writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(self.size.width),
                AVVideoHeightKey: Int(self.size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitRate(for: self.size),
                    AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: Self.framesPerSecond * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        // A film waits for the encoder rather than losing frames to it.
        input.expectsMediaDataInRealTime = film == nil
        // The encoder's own format, in memory the graphics card draws into directly.
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(self.size.width),
                kCVPixelBufferHeightKey as String: Int(self.size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw AppletError("Video encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AppletError("Cannot start video encoder.")
        }
        writer.startSession(atSourceTime: .zero)
    }
    /// Budgeted per pixel and capped: enough for a game in motion to stay sharp, small enough to post.
    nonisolated static func bitRate(for size: CGSize) -> Int {
        let pixels = Double(size.width * size.height) * Double(framesPerSecond)
        return Int(min(max(pixels * 0.4, 2_000_000), 12_000_000))
    }
    func start(snapshot: @escaping @MainActor () async throws -> NSImage, duration: Double) {
        limit = Int(((duration + 1) * Self.audioRate).rounded()) * 2
        self.duration = duration
        started = ContinuousClock.now
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Recording a noodlet")
        task = Task { [weak self, film] in
            if let film, await film.begin() {
                await self?.film(film, snapshot: snapshot, duration: duration)
                await film.end()
            } else {
                await self?.live(snapshot, duration: duration)
            }
            self?.endActivity()
        }
    }
    /// Returns once capturing has ended: every frame is in, or the recording failed or was stopped.
    func captured() async { await task?.value }
    /// Every frame, one after another: the page's clock moves on exactly one frame, the page draws
    /// it, and the picture goes in at that frame's time. A page that takes longer to draw than its
    /// frames last is slowed down rather than skipped, so the video stays smooth; one that draws
    /// faster waits, so it never runs ahead of real time and its sound stays with its picture.
    private func film(
        _ film: Film, snapshot: @MainActor () async throws -> NSImage, duration: Double
    ) async {
        let clock = ContinuousClock(), start = clock.now
        let last = Int64((duration * Double(Self.framesPerSecond)).rounded())
        var slot: Int64 = 0
        while !Task.isCancelled, slot < last {
            do {
                if slot > 0 {
                    let wait = Self.wait(before: slot, elapsed: Self.seconds(clock.now - start))
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    try await film.advance()
                }
                let image = try await snapshot()
                try await append(image, at: CMTime(value: slot, timescale: Self.framesPerSecond), patient: true)
                slot += 1
            } catch is CancellationError { break } catch {
                failure = error
                break
            }
        }
    }
    /// How long to wait before filming `slot`, `elapsed` seconds into the recording, so the
    /// page's clock never runs ahead of real time.
    nonisolated static func wait(before slot: Int64, elapsed: Double) -> Double {
        max(0, Double(slot) / Double(framesPerSecond) - elapsed)
    }
    /// Whatever the page shows as each slot comes round, for a page that cannot be filmed.
    private func live(_ snapshot: @MainActor () async throws -> NSImage, duration: Double) async {
        let rate = Double(Self.framesPerSecond)
        let clock = ContinuousClock(), start = clock.now
        let last = Int64((duration * rate).rounded())
        var slot: Int64 = 0
        while !Task.isCancelled, slot < last {
            do {
                let image = try await snapshot()
                try await append(image, at: CMTime(value: slot, timescale: Self.framesPerSecond), patient: false)
                let elapsed = Self.seconds(clock.now - start)
                slot = Self.slot(after: slot, elapsed: elapsed)
                let remaining = Double(slot) / rate - elapsed
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            } catch is CancellationError { break } catch {
                failure = error
                break
            }
        }
    }
    /// Sound a runner hands over: base64 of interleaved 16-bit stereo, at most 2 MiB a piece.
    nonisolated static func samples(_ encoded: Any?) -> [Int16]? {
        guard let encoded = encoded as? String, encoded.utf8.count <= 2 * 1_048_576,
            let data = Data(base64Encoded: encoded), data.count % 4 == 0
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
    /// Places interleaved stereo samples where they were heard, `seconds` after the recording
    /// started. Runners time their sound themselves, so a noodlet that starts playing late, or
    /// pauses, keeps its place however the samples arrive.
    func appendAudio(_ samples: [Int16], at seconds: Double) {
        guard seconds.isFinite, seconds >= 0, samples.count % 2 == 0 else { return }
        let start = Int((seconds * Self.audioRate).rounded()) * 2
        let end = min(start + samples.count, limit)
        guard start < end else { return }
        if sound.count < end { sound += repeatElement(0, count: end - sound.count) }
        sound.replaceSubrange(start..<end, with: samples[..<(end - start)])
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    /// The slot to capture next, given how long the recording has been running. Waiting a fixed
    /// interval after each capture would add the cost of the snapshot to every frame and set the
    /// rate by it. Taking the next slot that has not passed keeps the grid even and the recording
    /// in real time however slow the capture is.
    nonisolated static func slot(after slot: Int64, elapsed: Double) -> Int64 {
        max(slot + 1, Int64(elapsed * Double(framesPerSecond)) + 1)
    }
    /// A film waits for the encoder however long it takes (`patient`). Recording as the page runs,
    /// the encoder usually needs only a moment to catch up, and waiting for it must not block the
    /// noodlet being captured. Waiting longer than a frame would cost more than the frame is
    /// worth, so an encoder that stays behind loses this slot and the next capture takes a later
    /// one, which keeps the grid even.
    private func append(_ image: NSImage, at time: CMTime, patient: Bool) async throws {
        var waited = 0
        while !input.isReadyForMoreMediaData, patient || waited < 10 {
            if writer.status == .failed { throw writer.error ?? AppletError("Video encoding failed.") }
            try await Task.sleep(for: .milliseconds(patient ? 2 : 3))
            waited += 1
        }
        guard input.isReadyForMoreMediaData else { return }
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw AppletError("Cannot allocate video frame.") }
        try await drawer.draw(cg, into: buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? AppletError("Video encoding failed.")
        }
        frames += 1
    }
    func finish() async throws {
        // Stopped once its time is up, a film that fell behind still finishes the frames it owes.
        if film != nil, let started, let task, ContinuousClock.now - started >= .seconds(duration) {
            let deadline = Task {
                try? await Task.sleep(for: Self.catchUp)
                task.cancel()
            }
            await task.value
            deadline.cancel()
        }
        task?.cancel()
        await task?.value
        task = nil
        endActivity()
        if let failure {
            writer.cancelWriting()
            throw failure
        }
        guard frames > 0 else {
            writer.cancelWriting()
            throw AppletError("No video frames were captured.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppletError("Video could not be finalized.")
        }
        defer { try? FileManager.default.removeItem(at: videoURL) }
        if sound.isEmpty {
            try FileManager.default.moveItem(at: videoURL, to: url)
        } else {
            try await Self.mux(video: videoURL, sound: sound, to: url)
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        endActivity()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: videoURL)
    }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
    /// Copies the encoded picture as it is and adds the sound as AAC, cut to the picture's length.
    nonisolated private static func mux(video: URL, sound: [Int16], to url: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppletError("The recorded video has no picture.")
        }
        let length = try await asset.load(.duration)
        let hint = try await track.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: asset)
        // Read only from the one queue that feeds the picture input.
        nonisolated(unsafe) let pictures = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(pictures)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioRate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
        for input in [picture, audio] {
            guard writer.canAdd(input) else { throw AppletError("Video encoder is unavailable.") }
            writer.add(input)
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? AppletError("Cannot add sound to the video.")
        }
        writer.startSession(atSourceTime: .zero)
        let frames = min(sound.count / 2, Int(length.seconds * audioRate))
        let chunks = try SoundChunks(Array(sound[..<(frames * 2)]))
        async let copied: Void = pump(picture) { pictures.copyNextSampleBuffer() }
        async let encoded: Void = pump(audio) { chunks.next() }
        _ = await (copied, encoded)
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? AppletError("Cannot read the recorded video.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppletError("Video could not be finalized.")
        }
    }
    /// Feeds one input until its source runs dry. The writer interleaves by holding back
    /// whichever input is ahead, so each input needs its own queue.
    nonisolated private static func pump(
        _ input: AVAssetWriterInput, _ next: @escaping @Sendable () -> CMSampleBuffer?
    ) async {
        let queue = DispatchQueue(label: "NoodleApplet.Recording.\(input.mediaType.rawValue)")
        // Used only on its own queue once handed over.
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = SoundChunks.Flag()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !finished.value {
                    if let buffer = next(), input.append(buffer) { continue }
                    finished.value = true
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
    }
}

/// Draws captured pages into video frames on the graphics card, away from the main thread, so
/// recording does not hold up the page it records. The page is scaled to fill the frame, over
/// black where it is transparent, in standard colour.
private final class FrameDrawer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "NoodleApplet.Recording"])
    private let queue = DispatchQueue(label: "NoodleApplet.Recording.frames", qos: .userInitiated)
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func draw(_ image: CGImage, into buffer: CVPixelBuffer) async throws {
        // Both are used only on the drawing queue until it is done with them.
        nonisolated(unsafe) let image = image, buffer = buffer
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    let page = CIImage(cgImage: image).transformed(
                        by: CGAffineTransform(scaleX: width / CGFloat(image.width), y: height / CGFloat(image.height)))
                    let frame = page.composited(over: CIImage(color: .black).cropped(to: bounds))
                    let destination = CIRenderDestination(pixelBuffer: buffer)
                    destination.colorSpace = space
                    _ = try context.startTask(toRender: frame, from: bounds, to: destination, at: .zero)
                        .waitUntilCompleted()
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
        }
    }
}

/// Recorded sound cut into tenth-of-a-second sample buffers for the AAC encoder.
private final class SoundChunks: @unchecked Sendable {
    final class Flag: @unchecked Sendable { var value = false }
    private let samples: [Int16]
    private let format: CMAudioFormatDescription
    private var frame = 0
    private static let length = Int(AppletRecording.audioRate) / 10
    init(_ samples: [Int16]) throws {
        self.samples = samples
        var description = AudioStreamBasicDescription(
            mSampleRate: AppletRecording.audioRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format
        else { throw AppletError("Cannot describe the recorded sound.") }
        self.format = format
    }
    func next() -> CMSampleBuffer? {
        let count = min(Self.length, samples.count / 2 - frame)
        guard count > 0 else { return nil }
        defer { frame += count }
        let bytes = count * 4
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            samples.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress! + frame * 4, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: bytes)
            }) == noErr
        else { return nil }
        var buffer: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: count,
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(frame), timescale: CMTimeScale(AppletRecording.audioRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr
        else { return nil }
        return buffer
    }
}

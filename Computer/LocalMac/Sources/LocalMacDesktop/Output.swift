import AppKit
import Darwin
import Foundation
import LocalMacCore

final class Output {
    var onDisconnect: (@MainActor () -> Void)?
    private let queue = DispatchQueue(label: "LocalMac.output")
    /// Main queue only. Its two slots per stream also bound how many frames wait to be sent.
    private let frames = LocalMacFrameWriter()
    /// Takes ownership of `descriptor`.
    func send(_ value: LocalMacReply, descriptor: Int32? = nil, completion: (@MainActor () -> Void)? = nil) {
        queue.async {
            defer { if let descriptor { close(descriptor) } }
            do {
                try LocalMacWire.write(JSONEncoder().encode(value), to: .standardOutput, descriptor: descriptor)
                if let completion { DispatchQueue.main.async { completion() } }
            }
            catch { DispatchQueue.main.async { self.onDisconnect?() } }
        }
    }
    /// Copies a BGRA frame into shared memory and tells the app where it is. Dropped while the
    /// app still has both of the stream's slots.
    @MainActor func sendFrame(stream: UUID?, width: Int, height: Int, window: LocalMacWindowFrame? = nil,
                              copy: (UnsafeMutableRawPointer, _ bytesPerRow: Int) -> Void) throws {
        guard let written = try frames.write(stream: stream, width: width, height: height, copy: copy) else { return }
        if let (region, descriptor) = written.region {
            var announcement = LocalMacReply(); announcement.region = region
            send(announcement, descriptor: descriptor)
        }
        var reply = LocalMacReply(); reply.frame = true; reply.sharedFrame = written.frame; reply.windowFrame = window
        send(reply)
    }
    @MainActor func releaseFrame(_ frame: LocalMacSharedFrame) { frames.release(frame) }
    @MainActor func endFrames(stream: UUID?) { frames.end(stream: stream) }
    @MainActor func latestJPEG(stream: UUID?) -> Data? {
        frames.latestImage(stream: stream).flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
        }
    }
}

import CoreGraphics
import Darwin
import Foundation
import LocalMacPrivate

/// Frames reach the app through memory both sides map, so pixels are copied once on each side and
/// never encoded. Each stream (the desktop, or one window preview) has a region of two slots: the
/// helper writes a frame into a free slot and the app hands the slot back once it has copied it out.
/// A region is announced with its memory attached, and replaces the stream's previous region.
public struct LocalMacFrameRegion: Codable, Equatable, Sendable {
    public static let slots = 2
    /// 16 megapixels of BGRA, the most a window capture produces.
    public static let maximumSlotSize = 64 * 1_048_576
    public var id: UInt32
    /// The window preview, or nil for the desktop.
    public var stream: UUID?
    public var slotSize: Int
    public init(id: UInt32, stream: UUID?, slotSize: Int) { self.id = id; self.stream = stream; self.slotSize = slotSize }
}

/// Where a frame lies: BGRA rows, top first. Alpha is ignored, so transparent pixels show as black.
public struct LocalMacSharedFrame: Codable, Equatable, Sendable {
    public var region: UInt32
    public var slot: Int
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public init(region: UInt32, slot: Int, width: Int, height: Int, bytesPerRow: Int) {
        self.region = region; self.slot = slot; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
    }
    /// The frame's byte count when it fits in a slot of `slotSize`.
    func size(in slotSize: Int) -> Int? {
        guard (0..<LocalMacFrameRegion.slots).contains(slot), width > 0, height > 0,
              width <= bytesPerRow / 4 else { return nil }
        let (size, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return !overflow && size <= slotSize ? size : nil
    }
    func image(copying memory: UnsafeRawPointer) -> CGImage? {
        let data = Data(bytes: memory, count: bytesPerRow * height) as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private final class Mapping {
    let memory: UnsafeMutableRawPointer
    let length: Int
    init(memory: UnsafeMutableRawPointer, length: Int) { self.memory = memory; self.length = length }
    deinit { munmap(memory, length) }
}

/// The helper's side. Use it from one thread.
public final class LocalMacFrameWriter {
    public struct Written {
        /// A new region and its memory's descriptor, which the caller sends and then closes.
        public var region: (LocalMacFrameRegion, Int32)?
        public var frame: LocalMacSharedFrame
    }
    private final class Region {
        let info: LocalMacFrameRegion
        let mapping: Mapping
        var busy = [Bool](repeating: false, count: LocalMacFrameRegion.slots)
        var latest: LocalMacSharedFrame?
        init(info: LocalMacFrameRegion, mapping: Mapping) { self.info = info; self.mapping = mapping }
    }
    private var regions: [UUID?: Region] = [:]
    private var lastID: UInt32 = 0
    public init() {}

    /// Copies a frame into a free slot of the stream's region, making a larger region first when
    /// needed. `copy` gets the slot and its row length. Nil when both slots are still with the app.
    public func write(stream: UUID?, width: Int, height: Int,
                      copy: (UnsafeMutableRawPointer, _ bytesPerRow: Int) -> Void) throws -> Written? {
        let bytesPerRow = width * 4
        guard width > 0, height > 0, width <= LocalMacFrameRegion.maximumSlotSize / 4,
              height <= LocalMacFrameRegion.maximumSlotSize / bytesPerRow else {
            throw LocalMacError("The picture is too large to show.")
        }
        var announced: (LocalMacFrameRegion, Int32)?
        if regions[stream].map({ $0.info.slotSize < bytesPerRow * height }) ?? true {
            // Room to grow by a quarter, so resizing a window does not remake the region every frame.
            let page = Int(getpagesize()), wanted = min(LocalMacFrameRegion.maximumSlotSize, bytesPerRow * height * 5 / 4)
            let slotSize = (wanted + page - 1) / page * page, length = slotSize * LocalMacFrameRegion.slots
            let descriptor = NLMCreateSharedMemory(length)
            guard descriptor >= 0 else { throw LocalMacError("Cannot set aside memory for the picture.") }
            let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
            guard let memory, memory != MAP_FAILED else { close(descriptor); throw LocalMacError("Cannot set aside memory for the picture.") }
            lastID &+= 1
            let info = LocalMacFrameRegion(id: lastID, stream: stream, slotSize: slotSize)
            regions[stream] = Region(info: info, mapping: Mapping(memory: memory, length: length))
            announced = (info, descriptor)
        }
        let region = regions[stream]!
        guard let slot = region.busy.firstIndex(of: false) else { return nil }
        copy(region.mapping.memory + slot * region.info.slotSize, bytesPerRow)
        region.busy[slot] = true
        let frame = LocalMacSharedFrame(region: region.info.id, slot: slot, width: width, height: height, bytesPerRow: bytesPerRow)
        region.latest = frame
        return Written(region: announced, frame: frame)
    }
    public func release(_ frame: LocalMacSharedFrame) {
        guard let region = regions.values.first(where: { $0.info.id == frame.region }),
              region.busy.indices.contains(frame.slot) else { return }
        region.busy[frame.slot] = false
    }
    public func end(stream: UUID?) { regions[stream] = nil }
    /// A copy of the stream's newest frame.
    public func latestImage(stream: UUID?) -> CGImage? {
        guard let region = regions[stream], let frame = region.latest else { return nil }
        return frame.image(copying: region.mapping.memory + frame.slot * region.info.slotSize)
    }
}

/// The app's side. Safe to use from any thread.
public final class LocalMacFrameReader: @unchecked Sendable {
    private struct Region { let info: LocalMacFrameRegion; let mapping: Mapping }
    private let lock = NSLock()
    private var regions: [UInt32: Region] = [:]
    public init() {}

    /// Maps a region the helper announced, replacing its stream's previous one, and closes `descriptor`.
    public func add(_ region: LocalMacFrameRegion, descriptor: Int32) throws {
        defer { close(descriptor) }
        let (length, overflow) = region.slotSize.multipliedReportingOverflow(by: LocalMacFrameRegion.slots)
        guard (1...LocalMacFrameRegion.maximumSlotSize).contains(region.slotSize), !overflow,
              NLMIsSharedMemory(descriptor, length) else {
            throw LocalMacError("The desktop helper sent memory that cannot hold its pictures.")
        }
        let memory = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0)
        guard let memory, memory != MAP_FAILED else { throw LocalMacError("Cannot read the desktop helper's pictures.") }
        let mapping = Mapping(memory: memory, length: length)
        try lock.withLock {
            let others = regions.filter { $0.value.info.stream != region.stream }
            // Every window preview and the desktop, plus one whose preview is closing.
            guard regions[region.id] == nil, others.count <= LocalMacWindowCaptureLimits.maximumWindows + 1 else {
                throw LocalMacError("The desktop helper sent more pictures than it shows.")
            }
            regions = others
            regions[region.id] = Region(info: region, mapping: mapping)
        }
    }
    /// A copy of the frame, or nil when it does not lie within a known region.
    public func image(_ frame: LocalMacSharedFrame) -> CGImage? {
        lock.withLock {
            guard let region = regions[frame.region], frame.size(in: region.info.slotSize) != nil else { return nil }
            return frame.image(copying: region.mapping.memory + frame.slot * region.info.slotSize)
        }
    }
    public func remove(stream: UUID?) { lock.withLock { regions = regions.filter { $0.value.info.stream != stream } } }
    public func removeAll() { lock.withLock { regions.removeAll() } }
}

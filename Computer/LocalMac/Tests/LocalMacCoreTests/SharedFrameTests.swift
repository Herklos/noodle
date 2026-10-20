import Darwin
import Foundation
import XCTest
@testable import LocalMacCore

final class SharedFrameTests: XCTestCase {
    private func write(_ writer: LocalMacFrameWriter, stream: UUID? = nil, width: Int, height: Int,
                       value: UInt8) throws -> LocalMacFrameWriter.Written? {
        try writer.write(stream: stream, width: width, height: height) { memory, bytesPerRow in
            for row in 0..<height { memset(memory + row * bytesPerRow, Int32(value), width * 4) }
        }
    }
    private func send(_ reply: LocalMacReply, descriptor: Int32? = nil, to handle: FileHandle) throws {
        try LocalMacWire.write(JSONEncoder().encode(reply), to: handle, descriptor: descriptor)
        if let descriptor { close(descriptor) }
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return (0..<image.height).flatMap { row in data[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)] }
    }

    func testFramesCrossThroughSharedMemoryLosslessly() throws {
        let (helper, app) = try LocalMacWire.socketPair()
        let writer = LocalMacFrameWriter(), frames = LocalMacFrameReader(), reader = LocalMacWire.Reader(app)
        let written = try XCTUnwrap(write(writer, width: 3, height: 2, value: 0x5a))
        let (region, descriptor) = try XCTUnwrap(written.region)
        var announcement = LocalMacReply(); announcement.region = region
        try send(announcement, descriptor: descriptor, to: helper)
        var frame = LocalMacReply(); frame.frame = true; frame.sharedFrame = written.frame
        try send(frame, to: helper)

        let first = try LocalMacWire.decode(LocalMacReply.self, from: XCTUnwrap(reader.read()))
        try frames.add(XCTUnwrap(first.region), descriptor: XCTUnwrap(reader.takeDescriptor()))
        XCTAssertNil(reader.takeDescriptor())
        let second = try LocalMacWire.decode(LocalMacReply.self, from: XCTUnwrap(reader.read()))
        XCTAssertNil(second.data, "Frames no longer carry encoded pictures.")
        let image = try XCTUnwrap(frames.image(XCTUnwrap(second.sharedFrame)))
        XCTAssertEqual([image.width, image.height], [3, 2])
        XCTAssertEqual(pixels(image), [UInt8](repeating: 0x5a, count: 24))
    }

    func testSlotsWaitForTheAppAndGrowingReplacesTheRegion() throws {
        let writer = LocalMacFrameWriter()
        let first = try XCTUnwrap(write(writer, width: 4, height: 4, value: 1))
        let second = try XCTUnwrap(write(writer, width: 4, height: 4, value: 2))
        XCTAssertNotNil(first.region); XCTAssertNil(second.region)
        XCTAssertNotEqual(first.frame.slot, second.frame.slot)
        if let descriptor = first.region?.1 { close(descriptor) }
        XCTAssertNil(try write(writer, width: 4, height: 4, value: 3), "Both slots are still with the app.")
        writer.release(first.frame)
        let third = try XCTUnwrap(write(writer, width: 4, height: 4, value: 3))
        XCTAssertEqual(third.frame.slot, first.frame.slot)
        XCTAssertEqual(writer.latestImage(stream: nil).map(pixels)?.first, 3)

        let preview = UUID()
        let window = try XCTUnwrap(write(writer, stream: preview, width: 4, height: 4, value: 4))
        XCTAssertEqual(window.region?.0.stream, preview, "Each stream has its own slots.")
        if let descriptor = window.region?.1 { close(descriptor) }

        let larger = try XCTUnwrap(write(writer, width: 4000, height: 3000, value: 5))
        let (region, descriptor) = try XCTUnwrap(larger.region); close(descriptor)
        XCTAssertNotEqual(region.id, first.region?.0.id)
        XCTAssertGreaterThanOrEqual(region.slotSize, 4000 * 3000 * 4)
        XCTAssertNotNil(try write(writer, width: 4000, height: 3000, value: 6))
        writer.release(second.frame)
        XCTAssertNil(try write(writer, width: 4000, height: 3000, value: 7),
                     "Releasing a slot of the replaced region must not free one in the new region.")
        XCTAssertThrowsError(try write(writer, width: 8193, height: 2049, value: 8))
    }

    func testAppRefusesMemoryTheHelperCouldShrinkAndFramesOutsideTheRegion() throws {
        let frames = LocalMacFrameReader(), writer = LocalMacFrameWriter()
        let region = LocalMacFrameRegion(id: 1, stream: nil, slotSize: 16_384)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(count: 65_536).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try frames.add(region, descriptor: open(file.path, O_RDONLY)), "A file can be truncated under the mapping.")
        var pipes: [Int32] = [0, 0]; pipe(&pipes); close(pipes[1])
        XCTAssertThrowsError(try frames.add(region, descriptor: pipes[0]))

        let written = try XCTUnwrap(write(writer, width: 2, height: 2, value: 9))
        let (announced, descriptor) = try XCTUnwrap(written.region)
        var oversized = announced; oversized.slotSize = announced.slotSize * 4
        XCTAssertThrowsError(try frames.add(oversized, descriptor: dup(descriptor)), "The memory must hold every slot it claims.")
        try frames.add(announced, descriptor: descriptor)
        XCTAssertNotNil(frames.image(written.frame))
        let changes: [(inout LocalMacSharedFrame) -> Void] = [
            { $0.slot = LocalMacFrameRegion.slots }, { $0.slot = -1 }, { $0.region = 99 }, { $0.bytesPerRow = 4 },
            { $0.width = 0 }, { $0.height = Int.max / 2 }, { $0.height = announced.slotSize / $0.bytesPerRow + 1 }]
        for change in changes {
            var frame = written.frame; change(&frame)
            XCTAssertNil(frames.image(frame))
        }
        frames.remove(stream: nil)
        XCTAssertNil(frames.image(written.frame))
    }
}

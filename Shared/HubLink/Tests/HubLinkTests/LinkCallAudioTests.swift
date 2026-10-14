import Foundation
@testable import HubLink
import XCTest

final class LinkCallAudioTests: XCTestCase {
    func testAudioFramesAreToldApartFromEvents() {
        let packet = Data([0x7b, 0x01, 0x02])
        let frame = LinkCallAudio.frame(packet)
        XCTAssertEqual(LinkCallAudio.packet(in: frame), packet)
        XCTAssertNil(LinkCallEvent(frame))
        XCTAssertNil(LinkCallAudio.packet(in: LinkCallEvent.started.encoded))
        XCTAssertNil(LinkCallAudio.packet(in: Data()))
    }

    func testSpeechSurvivesTheCodecAtAFewDozenBytesAFrame() throws {
        let encoder = try LinkCallEncoder()
        let decoder = try LinkCallDecoder()
        // A second of a 440 Hz tone, handed over in uneven pieces as capture does.
        let tone = (0..<LinkCallAudio.sampleRate).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(LinkCallAudio.sampleRate)) * 8000) }
        var packets: [Data] = []
        var start = 0
        for size in [100, 2000, 37, 5000] + Array(repeating: 4000, count: 11) where start < tone.count {
            packets += try encoder.encode(Array(tone[start..<min(start + size, tone.count)]))
            start += size
        }
        XCTAssertEqual(packets.count, LinkCallAudio.sampleRate / LinkCallAudio.frameSamples)
        XCTAssertLessThan(packets.map(\.count).max() ?? 0, 200)
        var decoded: [Int16] = []
        for packet in packets { decoded += try decoder.decode(packet) }
        XCTAssertGreaterThan(decoded.count, tone.count * 9 / 10)
        // The tone comes back loud, not as silence or noise.
        let tail = decoded.suffix(LinkCallAudio.sampleRate / 2)
        XCTAssertGreaterThan(tail.map { abs(Int($0)) }.max() ?? 0, 5000)
    }

    func testPlaybackWaitsForACushionAndRefillsItAfterRunningDry() {
        let buffer = LinkCallPlayout(cushion: 100, limit: 1000)
        var out = [Int16](repeating: 9, count: 50)
        buffer.append([Int16](repeating: 1, count: 60))
        buffer.read(into: &out)
        XCTAssertEqual(out, [Int16](repeating: 0, count: 50), "Starting before the cushion would stutter at once")
        buffer.append([Int16](repeating: 2, count: 60))
        buffer.read(into: &out)
        XCTAssertEqual(out, [Int16](repeating: 1, count: 50))
        var long = [Int16](repeating: 9, count: 100)
        buffer.read(into: &long)
        XCTAssertEqual(long, [Int16](repeating: 1, count: 10) + [Int16](repeating: 2, count: 60) + [Int16](repeating: 0, count: 30))
        buffer.append([Int16](repeating: 3, count: 50))
        buffer.read(into: &out)
        XCTAssertEqual(out, [Int16](repeating: 0, count: 50), "After running dry it waits for the cushion again")
    }

    func testPlaybackDropsTheOldestAudioWhenTooFarBehind() {
        let buffer = LinkCallPlayout(cushion: 10, limit: 100)
        buffer.append([Int16](repeating: 1, count: 80))
        buffer.append([Int16](repeating: 2, count: 80))
        var out = [Int16](repeating: 9, count: 100)
        buffer.read(into: &out)
        XCTAssertEqual(out, [Int16](repeating: 1, count: 20) + [Int16](repeating: 2, count: 80))
    }
}

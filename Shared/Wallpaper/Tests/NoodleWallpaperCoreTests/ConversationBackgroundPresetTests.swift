import Foundation
import XCTest
@testable import NoodleWallpaperCore

final class ConversationBackgroundPresetTests: XCTestCase {
    /// Presets come and go; a stored name this build no longer knows shows the default.
    func testUnknownPresetLoadsAsDefault() throws {
        let data = Data(#"{"preset":"retired","imageFilename":null}"#.utf8)
        let background = try JSONDecoder().decode(ConversationBackground.self, from: data)
        XCTAssertTrue(background.isDefault)
        let ocean = try JSONDecoder().decode(ConversationBackground.self, from: Data(#"{"preset":"ocean"}"#.utf8))
        XCTAssertEqual(ocean.preset, .ocean)
    }

    func testPresetsFillRowsOfTenWithDistinctColours() {
        let presets = ConversationBackgroundPreset.allCases
        XCTAssertEqual(presets.count, 40)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)
        XCTAssertEqual(Set(presets.map { $0.stops.map { [$0.red, $0.green, $0.blue] } }).count, presets.count)
        for preset in presets {
            XCTAssertEqual(preset.stops.count, 3, preset.name)
            for stop in preset.stops {
                XCTAssertTrue([stop.red, stop.green, stop.blue].allSatisfy { (0...1).contains($0) }, preset.name)
            }
        }
    }
}

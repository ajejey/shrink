import XCTest
@testable import ShrinkCore

/// shared/presets.json is bundled into the app. A broken entry should fail CI, not the app.
final class PresetsTests: XCTestCase {
    func testEveryPresetIsUsable() throws {
        let catalog = try Presets.load()
        XCTAssertFalse(catalog.presets.isEmpty)
        XCTAssertEqual(Set(catalog.presets.map(\.id)).count, catalog.presets.count, "ids are unique")
        for preset in catalog.presets {
            XCTAssertFalse(preset.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(preset.id) has a title")
            if let limit = preset.limitBytes {
                XCTAssertGreaterThan(limit, 0, "\(preset.id) limit")
            }
            if let source = preset.source {
                XCTAssertTrue(source.hasPrefix("https://"), "\(preset.id) source is a link")
                XCTAssertNotNil(preset.checked, "\(preset.id) says when its limit was checked")
            }
        }
        XCTAssertFalse(Presets.all.isEmpty)
    }
}

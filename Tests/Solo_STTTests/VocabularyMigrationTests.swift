import XCTest
@testable import Solo_STT

final class VocabularyMigrationTests: XCTestCase {
    func testMergePresetsIntoVocabulary() {
        let current = "React, TypeScript"
        let presetWords = ["Swift", "SwiftUI"]
        let merged = AppState.mergeVocabulary(current: current, presetWords: presetWords)
        XCTAssertTrue(merged.contains("React"))
        XCTAssertTrue(merged.contains("TypeScript"))
        XCTAssertTrue(merged.contains("Swift"))
        XCTAssertTrue(merged.contains("SwiftUI"))
    }

    func testNoDuplicatesAfterMerge() {
        let current = "React, Swift"
        let presetWords = ["Swift", "TypeScript"]
        let merged = AppState.mergeVocabulary(current: current, presetWords: presetWords)
        let parts = merged.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(parts.filter { $0 == "Swift" }.count, 1)
    }

    func testEmptyCurrentUsesDefault() {
        let merged = AppState.mergeVocabulary(current: "", presetWords: [])
        XCTAssertFalse(merged.isEmpty)
        XCTAssertTrue(merged.contains("React"))
    }
}

import XCTest
@testable import Solo_STT

final class WhisperModelMigrationTests: XCTestCase {
    func testLegacyGgmlSmallMapsToSmall() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("ggml-small.bin"), .small)
    }

    func testLegacyGgmlMediumMapsToTurbo() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("ggml-medium.bin"), .turbo)
    }

    func testLegacyGgmlLargeMapsToLargeV3() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("ggml-large.bin"), .largeV3)
    }

    func testNewIdentifierPassesThrough() {
        XCTAssertEqual(
            WhisperModel.migrateFromLegacy("openai_whisper-large-v3"),
            .largeV3
        )
    }

    func testUnknownDefaultsToTurbo() {
        XCTAssertEqual(WhisperModel.migrateFromLegacy("unknown.bin"), .turbo)
    }
}

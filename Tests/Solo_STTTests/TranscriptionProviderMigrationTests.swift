import XCTest
@testable import Solo_STT

final class TranscriptionProviderMigrationTests: XCTestCase {
    func testLegacyOpenAIProviderMigrates() {
        let result = AppState.migrateProvider(from: "openai")
        XCTAssertEqual(result.provider, "cloud")
        XCTAssertEqual(result.cloudService, "openai")
    }

    func testLegacyGroqProviderMigrates() {
        let result = AppState.migrateProvider(from: "groq")
        XCTAssertEqual(result.provider, "cloud")
        XCTAssertEqual(result.cloudService, "groq")
    }

    func testLegacyLogosSttMigratesToCustomServer() {
        let (provider, _) = AppState.migrateProvider(from: "logosStt")
        XCTAssertEqual(provider, "customServer")
    }

    func testModernLocalPassesThrough() {
        let (provider, _) = AppState.migrateProvider(from: "local")
        XCTAssertEqual(provider, "local")
    }
}

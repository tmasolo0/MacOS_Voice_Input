import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

actor TextCleanupService {
    enum CleanupError: LocalizedError {
        case unavailable
        case timeout

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Foundation Models unavailable"
            case .timeout:     return "Cleanup timed out"
            }
        }
    }

    #if canImport(FoundationModels)
    private var sessionStorage: Any?
    #endif

    private(set) var isAvailable: Bool = false

    init() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                self.isAvailable = false
                return
            }
            self.sessionStorage = LanguageModelSession(
                model: model,
                instructions: Self.cleanupInstructions
            )
            self.isAvailable = true
        } else {
            self.isAvailable = false
        }
        #else
        self.isAvailable = false
        #endif
    }

    func clean(_ raw: String, timeout: TimeInterval = 5.0) async throws -> String {
        guard !raw.isEmpty else { return raw }

        let wordCount = raw.split(separator: " ").count
        guard wordCount >= 5 else { return raw }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard let session = sessionStorage as? LanguageModelSession else {
                throw CleanupError.unavailable
            }
            return try await withTimeout(seconds: timeout) {
                let response = try await session.respond(to: raw)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            throw CleanupError.unavailable
        }
        #else
        throw CleanupError.unavailable
        #endif
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CleanupError.timeout
            }
            guard let result = try await group.next() else {
                throw CleanupError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private static let cleanupInstructions = """
    Ты — редактор расшифровок речи программиста.
    Задача: убрать заполнители, исправить пунктуацию,
    правильно капитализировать технические термины.

    Правила:
    - Убирай: «э», «эм», «ну», «типа», «короче», «вот».
    - Капитализируй: React, TypeScript, Claude, MCP, API, JSON, useEffect, useState.
    - Англ. термины оставляй в оригинальной нотации.
    - Не меняй фактуру, не перефразируй, не сокращай.
    - Возвращай ТОЛЬКО отредактированный текст, без объяснений.
    """
}

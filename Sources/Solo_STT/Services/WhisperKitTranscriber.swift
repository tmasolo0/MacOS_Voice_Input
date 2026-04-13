import Foundation
import WhisperKit

actor WhisperKitTranscriber {
    enum TranscriberError: LocalizedError {
        case notLoaded
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "WhisperKit model is not loaded"
            case .emptyResult: return "Transcription returned empty result"
            }
        }
    }

    struct Result {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    private var whisperKit: WhisperKit?
    private(set) var loadedVariant: String?

    func load(modelFolder: URL, variant: String, prewarm: Bool = true) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: prewarm,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        loadedVariant = variant
    }

    func transcribe(
        samples: [Float],
        language: String,
        vocabulary: String,
        temperatureFallbackCount: Int = 2
    ) async throws -> Result {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        let promptTokens: [Int]?
        if !vocabulary.isEmpty, let tokenizer = whisperKit.tokenizer {
            let encoded = tokenizer.encode(text: " \(vocabulary)")
            promptTokens = Array(encoded.prefix(224))
        } else {
            promptTokens = nil
        }

        let start = Date()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0.0,
                temperatureFallbackCount: temperatureFallbackCount,
                usePrefillPrompt: true,
                promptTokens: promptTokens
            )
        )
        let text = results.map(\.text).joined()
        let latency = Date().timeIntervalSince(start)

        return Result(
            text: text.trimmingCharacters(in: .whitespaces),
            language: language,
            latency: latency
        )
    }

    func unload() {
        whisperKit = nil
        loadedVariant = nil
    }
}

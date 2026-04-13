import Foundation

@MainActor
final class TranscriptionService {
    struct TranscriptionResultData {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    enum TranscriptionError: LocalizedError {
        case modelNotReady
        case noAPIKey

        var errorDescription: String? {
            switch self {
            case .modelNotReady: return "Модель не загружена для транскрипции"
            case .noAPIKey: return "API-ключ не задан"
            }
        }
    }

    private let modelService: ModelService
    private let appState: AppState
    private let cloudClient = CloudTranscriptionClient()

    init(modelService: ModelService, appState: AppState) {
        self.modelService = modelService
        self.appState = appState
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResultData {
        let provider = appState.currentProvider
        let language = appState.transcriptionLanguage

        switch provider {
        case .local:
            let vocabulary = appState.customVocabulary
            let r = try await modelService.transcriberActor().transcribe(
                samples: audioSamples,
                language: language,
                vocabulary: vocabulary
            )
            return TranscriptionResultData(text: r.text, language: r.language, latency: r.latency)

        case .cloud:
            let service = appState.cloudService
            let keychainKey = appState.cloudKeychainKey
            guard let apiKey = KeychainService.load(key: keychainKey), !apiKey.isEmpty else {
                throw TranscriptionError.noAPIKey
            }
            let baseURL: String
            let model: String
            switch service {
            case "groq":
                baseURL = "https://api.groq.com/openai/v1"
                model = "whisper-large-v3-turbo"
            default:
                baseURL = "https://api.openai.com/v1"
                model = "whisper-1"
            }
            let result = try await cloudClient.transcribe(
                audioSamples: audioSamples,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                language: language,
                useSimpleAPI: false,
                prompt: appState.customVocabulary.isEmpty ? nil : appState.customVocabulary
            )
            return TranscriptionResultData(text: result.text, language: language, latency: result.latency)

        case .customServer:
            let endpoint = appState.customEndpointURL
            let apiKey = KeychainService.load(key: provider.keychainKey)
            let result = try await cloudClient.transcribe(
                audioSamples: audioSamples,
                baseURL: endpoint,
                apiKey: apiKey,
                model: "",
                language: language,
                useSimpleAPI: true
            )
            return TranscriptionResultData(text: result.text, language: language, latency: result.latency)
        }
    }
}

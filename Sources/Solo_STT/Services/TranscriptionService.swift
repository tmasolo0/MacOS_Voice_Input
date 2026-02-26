import Foundation
import SwiftWhisper
import whisper_cpp

class TranscriptionService {
    private weak var modelService: ModelService?
    private weak var appState: AppState?
    private var initialPromptPtr: UnsafeMutablePointer<CChar>?
    private let cloudClient = CloudTranscriptionClient()

    init(modelService: ModelService, appState: AppState) {
        self.modelService = modelService
        self.appState = appState
    }

    deinit {
        freePrompt()
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResultData {
        guard let appState else {
            throw TranscriptionError.modelNotReady
        }

        let provider = appState.currentProvider
        if provider.isCloud {
            return try await transcribeCloud(audioSamples: audioSamples, provider: provider)
        }

        return try await transcribeLocal(audioSamples: audioSamples)
    }

    // MARK: - Cloud Transcription

    private func transcribeCloud(audioSamples: [Float], provider: TranscriptionProvider) async throws -> TranscriptionResultData {
        let language = appState?.transcriptionLanguage ?? "ru"

        let baseURL: String
        let apiKey: String?
        let model: String
        let useSimpleAPI: Bool

        switch provider {
        case .cloud:
            let service = appState?.cloudService ?? "openai"
            let keychainKey = appState?.cloudKeychainKey ?? "apiKey-openai"
            guard let key = KeychainService.load(key: keychainKey), !key.isEmpty else {
                throw TranscriptionError.noAPIKey
            }
            apiKey = key
            switch service {
            case "groq":
                baseURL = "https://api.groq.com/openai/v1"
                model = "whisper-large-v3-turbo"
            default:
                baseURL = "https://api.openai.com/v1"
                model = "whisper-1"
            }
            useSimpleAPI = false

        case .customServer:
            baseURL = appState?.customEndpointURL ?? ""
            apiKey = KeychainService.load(key: provider.keychainKey)
            model = ""
            useSimpleAPI = true

        case .local:
            // Should not reach here
            throw TranscriptionError.modelNotReady
        }

        let result = try await cloudClient.transcribe(
            audioSamples: audioSamples,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            language: language,
            useSimpleAPI: useSimpleAPI
        )

        return TranscriptionResultData(
            text: result.text,
            language: language,
            latency: result.latency
        )
    }

    // MARK: - Local Transcription

    private func transcribeLocal(audioSamples: [Float]) async throws -> TranscriptionResultData {
        guard let whisper = modelService?.whisper else {
            throw TranscriptionError.modelNotReady
        }

        // Preprocess audio: trim silence, normalize
        let processed = preprocessAudio(audioSamples)
        guard !processed.isEmpty else {
            return TranscriptionResultData(text: "", language: "ru", latency: 0)
        }

        // Configure params
        let language = appState?.transcriptionLanguage ?? "ru"
        if language == "auto" {
            whisper.params.language = .auto
        } else {
            whisper.params.language = WhisperLanguage(rawValue: language) ?? .auto
        }
        whisper.params.temperature = Float(appState?.whisperTemperature ?? 0.3)
        whisper.params.entropy_thold = Float(appState?.whisperEntropyThreshold ?? 2.4)
        whisper.params.logprob_thold = Float(appState?.whisperLogprobThreshold ?? -1.0)
        whisper.params.no_speech_thold = 0.6
        whisper.params.no_context = true
        whisper.params.suppress_blank = true
        whisper.params.suppress_non_speech_tokens = true

        // Initial prompt improves Russian recognition and punctuation
        setInitialPrompt(for: language, params: whisper.params)

        // Beam search for higher accuracy (optional)
        let useBeamSearch = appState?.useBeamSearch ?? false
        if useBeamSearch {
            whisper.params.strategy = WHISPER_SAMPLING_BEAM_SEARCH
            whisper.params.beam_search.beam_size = 5
        } else {
            whisper.params.strategy = WHISPER_SAMPLING_GREEDY
        }

        let startTime = Date()
        let segments = try await whisper.transcribe(audioFrames: processed)
        let latency = Date().timeIntervalSince(startTime)

        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionResultData(
            text: text,
            language: language,
            latency: latency
        )
    }

    // MARK: - Audio Preprocessing

    /// Trim silence from start/end and normalize volume
    private func preprocessAudio(_ samples: [Float]) -> [Float] {
        // 1. Trim silence (energy-based VAD)
        let trimmed = trimSilence(samples)
        guard !trimmed.isEmpty else { return [] }

        // 2. Normalize volume to [-1, 1] range
        return normalize(trimmed)
    }

    /// Remove leading and trailing silence based on RMS energy
    private func trimSilence(_ samples: [Float], threshold: Float = 0.008, windowSize: Int = 800) -> [Float] {
        // windowSize = 800 samples @ 16kHz = 50ms windows
        guard samples.count > windowSize else { return samples }

        // Find first window above threshold (start of speech)
        var startIndex = 0
        for i in stride(from: 0, to: samples.count - windowSize, by: windowSize / 2) {
            let rms = rmsEnergy(samples, from: i, count: windowSize)
            if rms > threshold {
                // Back up a bit to not clip the onset
                startIndex = max(0, i - windowSize)
                break
            }
        }

        // Find last window above threshold (end of speech)
        var endIndex = samples.count
        for i in stride(from: samples.count - windowSize, through: 0, by: -(windowSize / 2)) {
            let rms = rmsEnergy(samples, from: i, count: windowSize)
            if rms > threshold {
                // Extend a bit to not clip the tail
                endIndex = min(samples.count, i + windowSize * 2)
                break
            }
        }

        guard startIndex < endIndex else { return [] }
        return Array(samples[startIndex..<endIndex])
    }

    private func rmsEnergy(_ samples: [Float], from start: Int, count: Int) -> Float {
        let end = min(start + count, samples.count)
        guard end > start else { return 0 }
        var sum: Float = 0
        for i in start..<end {
            sum += samples[i] * samples[i]
        }
        return sqrtf(sum / Float(end - start))
    }

    /// Normalize audio to use full dynamic range
    private func normalize(_ samples: [Float]) -> [Float] {
        let maxAbs = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAbs > 0.001 else { return samples }  // too quiet, skip
        let gain = min(1.0 / maxAbs, 10.0)  // cap at 10x to avoid amplifying noise
        guard gain > 1.1 else { return samples }  // already loud enough
        return samples.map { $0 * gain }
    }

    // MARK: - Initial Prompt

    private func setInitialPrompt(for language: String, params: WhisperParams) {
        freePrompt()
        let basePrompt: String
        switch language {
        case "ru": basePrompt = "Привет. Это диктовка на русском языке."
        case "auto": return
        default: return
        }

        // Collect terms from active presets
        var extraTerms: [String] = []
        if let presetIds = appState?.selectedPresets {
            for id in presetIds {
                if let preset = VocabularyPreset(rawValue: id) {
                    extraTerms.append(preset.terms)
                }
            }
        }

        // Add custom vocabulary
        if let custom = appState?.customVocabulary, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            extraTerms.append(custom.trimmingCharacters(in: .whitespaces))
        }

        let prompt: String
        if extraTerms.isEmpty {
            prompt = basePrompt
        } else {
            prompt = basePrompt + " " + extraTerms.joined(separator: ", ")
        }

        initialPromptPtr = strdup(prompt)
        if let ptr = initialPromptPtr {
            params.initial_prompt = UnsafePointer(ptr)
        }
    }

    private func freePrompt() {
        if let ptr = initialPromptPtr {
            free(ptr)
            initialPromptPtr = nil
        }
    }

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
}

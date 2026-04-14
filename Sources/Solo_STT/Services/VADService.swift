import Foundation
import CoreML

actor VADService {
    enum VADError: LocalizedError {
        case modelNotFound
        case inferenceFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:    return "Silero VAD model not found in bundle"
            case .inferenceFailed:  return "VAD inference failed"
            }
        }
    }

    private var model: MLModel?
    private let sampleRate: Int = 16000
    private let windowSamples: Int = 512 // 32ms @ 16kHz

    init() {
        guard let url = Bundle.main.url(
            forResource: "silero_vad",
            withExtension: "mlmodelc"
        ) else {
            DiagnosticLogger.shared.error(
                "Silero VAD model not in bundle", category: "VAD"
            )
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            self.model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            DiagnosticLogger.shared.error(
                "Failed to load VAD model: \(error)", category: "VAD"
            )
        }
    }

    /// Возвращает диапазон индексов с речью, либо nil если речь не найдена.
    func trim(
        samples: [Float],
        speechThreshold: Float = 0.5,
        minSpeechDurationMs: Int = 250,
        speechPadMs: Int = 150
    ) async throws -> Range<Int>? {
        guard let model else {
            // Fallback: VAD не инициализирован → возвращаем весь диапазон
            return samples.isEmpty ? nil : 0..<samples.count
        }

        guard samples.count >= windowSamples else { return nil }

        var probs: [Float] = []

        for windowStart in stride(from: 0, to: samples.count - windowSamples, by: windowSamples) {
            let window = Array(samples[windowStart..<(windowStart + windowSamples)])
            let input = try MLMultiArray(shape: [1, NSNumber(value: windowSamples)], dataType: .float32)
            for (i, v) in window.enumerated() { input[i] = NSNumber(value: v) }

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_chunk": MLFeatureValue(multiArray: input),
            ])

            let output = try await model.prediction(from: features)
            if let prob = output.featureValue(for: "vad_probability")?.multiArrayValue {
                probs.append(prob[0].floatValue)
            }
        }

        // Соберём speech segments
        let minWindows = max(1, minSpeechDurationMs / 32)
        let padWindows = max(0, speechPadMs / 32)

        var firstSpeech: Int? = nil
        var lastSpeech: Int? = nil
        var runLen = 0
        for (i, p) in probs.enumerated() {
            if p >= speechThreshold {
                runLen += 1
                if runLen >= minWindows {
                    if firstSpeech == nil { firstSpeech = i - runLen + 1 }
                    lastSpeech = i
                }
            } else {
                runLen = 0
            }
        }

        guard let first = firstSpeech, let last = lastSpeech else { return nil }

        let startWindow = max(0, first - padWindows)
        let endWindow = min(probs.count - 1, last + padWindows)
        let startSample = startWindow * windowSamples
        let endSample = min(samples.count, (endWindow + 1) * windowSamples)
        return startSample..<endSample
    }
}

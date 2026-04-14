import Foundation
import AVFAudio
#if canImport(Speech)
import Speech
#endif

actor AppleSpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case unavailable
        case authorizationDenied

        var errorDescription: String? {
            switch self {
            case .unavailable:           return "SpeechAnalyzer unavailable (macOS 26 required)"
            case .authorizationDenied:   return "Speech recognition not authorized"
            }
        }
    }

    struct Result {
        let text: String
        let language: String
        let latency: TimeInterval
    }

    func transcribe(
        samples: [Float],
        language: String
    ) async throws -> Result {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            let locale = Locale(identifier: language == "auto" ? "ru_RU" : language)
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            let buffer = try samplesToPCMBuffer(samples: samples)
            let start = Date()

            let inputStream = AsyncStream<AnalyzerInput> { continuation in
                continuation.yield(AnalyzerInput(buffer: buffer))
                continuation.finish()
            }

            let analyzeTask = Task {
                _ = try? await analyzer.analyzeSequence(inputStream)
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            var resultText = ""
            for try await segment in transcriber.results {
                resultText += String(segment.text.characters)
            }
            _ = await analyzeTask.value

            let latency = Date().timeIntervalSince(start)
            return Result(text: resultText.trimmingCharacters(in: .whitespaces),
                          language: language,
                          latency: latency)
        } else {
            throw TranscriberError.unavailable
        }
        #else
        throw TranscriberError.unavailable
        #endif
    }

    private func samplesToPCMBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(
                from: ptr.baseAddress!, count: samples.count
            )
        }
        return buffer
    }
}

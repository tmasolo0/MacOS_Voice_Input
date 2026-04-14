import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case local
    case appleSpeech = "apple_speech"
    case customServer
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:        return "Локальный — WhisperKit (рекомендуется)"
        case .appleSpeech:  return "Локальный — Apple Speech (macOS 26)"
        case .cloud:        return "Облачный — OpenAI / Groq"
        case .customServer: return "Свой сервер"
        }
    }

    var shortLabel: String {
        switch self {
        case .local:        return ""
        case .appleSpeech:  return "AS"
        case .customServer: return "S"
        case .cloud:        return "C"
        }
    }

    var isCloud: Bool {
        switch self {
        case .local, .appleSpeech:  return false
        case .cloud, .customServer: return true
        }
    }

    var keychainKey: String {
        "apiKey-\(rawValue)"
    }

    static var `default`: TranscriptionProvider { .local }
}

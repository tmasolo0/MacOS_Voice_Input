import Foundation

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case turbo   = "large-v3-turbo"
    case largeV3 = "large-v3"
    case small   = "small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turbo:   return "Large v3 Turbo (1.5 GB, рекомендуется)"
        case .largeV3: return "Large v3 (3 GB, максимум качества)"
        case .small:   return "Small (250 MB, быстро и слабо)"
        }
    }

    var approximateSizeMB: Int {
        switch self {
        case .turbo:   return 1500
        case .largeV3: return 3000
        case .small:   return 250
        }
    }

    /// Имя папки модели в HuggingFace repo argmaxinc/whisperkit-coreml.
    /// Используется для локальной проверки наличия модели на диске после snapshot download.
    var folderName: String {
        switch self {
        case .turbo:   return "openai_whisper-large-v3-turbo"
        case .largeV3: return "openai_whisper-large-v3"
        case .small:   return "openai_whisper-small"
        }
    }

    static var `default`: WhisperModel { .turbo }
    static var all: [WhisperModel] { Self.allCases }

    /// Маппинг устаревших имён моделей на текущие WhisperKit-варианты.
    /// Используется при миграции UserDefaults с v1 (GGML) или ранних v2-сборок.
    static func migrateFromLegacy(_ legacy: String) -> WhisperModel {
        switch legacy {
        case "ggml-small.bin",  "openai_whisper-small":            return .small
        case "ggml-medium.bin", "openai_whisper-large-v3-turbo",
             "openai_whisper-large-v3-turbo_turbo_600MB":          return .turbo
        case "ggml-large.bin",  "openai_whisper-large-v3":         return .largeV3
        default:
            return WhisperModel(rawValue: legacy) ?? .default
        }
    }
}

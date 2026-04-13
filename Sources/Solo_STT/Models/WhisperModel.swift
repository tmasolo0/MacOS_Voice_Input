import Foundation

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case turboQuantized = "openai_whisper-large-v3-turbo_turbo_600MB"
    case turbo          = "openai_whisper-large-v3-turbo"
    case largeV3        = "openai_whisper-large-v3"
    case small          = "openai_whisper-small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turboQuantized: return "Large v3 Turbo (600 MB, квантизованная)"
        case .turbo:          return "Large v3 Turbo (1.5 GB, рекомендуется)"
        case .largeV3:        return "Large v3 (3 GB, максимум качества)"
        case .small:          return "Small (250 MB, быстро и слабо)"
        }
    }

    var approximateSizeMB: Int {
        switch self {
        case .turboQuantized: return 600
        case .turbo:          return 1500
        case .largeV3:        return 3000
        case .small:          return 250
        }
    }

    static var `default`: WhisperModel { .turbo }
    static var all: [WhisperModel] { Self.allCases }

    /// Маппинг устаревших GGML-имён на новые WhisperKit-варианты.
    /// Используется при миграции UserDefaults с v1 на v2.
    static func migrateFromLegacy(_ legacy: String) -> WhisperModel {
        switch legacy {
        case "ggml-small.bin":  return .small
        case "ggml-medium.bin": return .turbo
        case "ggml-large.bin":  return .largeV3
        default:
            return WhisperModel(rawValue: legacy) ?? .default
        }
    }
}

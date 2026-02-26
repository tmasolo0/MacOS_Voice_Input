import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case customServer
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Локальная"
        case .customServer: return "Свой сервер"
        case .cloud: return "Облако"
        }
    }

    /// Короткая метка для отображения рядом с иконкой в трее
    var shortLabel: String {
        switch self {
        case .local: return ""
        case .customServer: return "S"
        case .cloud: return "C"
        }
    }

    var isCloud: Bool {
        self != .local
    }

    var keychainKey: String {
        "apiKey-\(rawValue)"
    }
}
